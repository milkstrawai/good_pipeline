# frozen_string_literal: true

module GoodPipeline
  class Coordinator # rubocop:disable Metrics/ClassLength
    ACTIVE_STEP_STATUSES = %w[pending enqueued].freeze

    class << self
      # Requests a graceful cancellation. Pending work is canceled immediately;
      # jobs that GoodJob already owns are allowed to reach their real outcome.
      def cancel_pipeline(pipeline_or_id) # rubocop:disable Metrics/MethodLength
        pipeline_id = record_id(pipeline_or_id)

        PipelineRecord.transaction do
          pipeline = PipelineRecord.lock("FOR UPDATE").find(pipeline_id)

          case pipeline.status
          when "pending"
            cancel_pending_steps_locked(pipeline)
            transition_pipeline_to_terminal_locked!(pipeline, :canceled)
          when "running"
            pipeline.transition_to!(:canceling)
            cancel_pending_steps_locked(pipeline)
            recompute_pipeline_status_locked!(pipeline)
          when "canceling"
            # Re-apply the pending-step update so repeated requests keep the
            # scheduling barrier enforced idempotently.
            cancel_pending_steps_locked(pipeline)
            recompute_pipeline_status_locked!(pipeline)
          when "canceled"
            # Cancellation is intentionally idempotent.
          else
            raise CancellationConflict.new(pipeline_id: pipeline.id, status: pipeline.status)
          end

          pipeline
        end
      end

      def complete_step(step_or_id, succeeded:, pipeline_id: nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        step_id = record_id(step_or_id)
        pipeline_id ||= step_or_id.pipeline_id if step_or_id.respond_to?(:pipeline_id)
        pipeline_id ||= pipeline_id_for_step!(step_id)

        PipelineRecord.transaction do
          pipeline = PipelineRecord.lock("FOR UPDATE").find(pipeline_id)
          step = StepRecord.lock("FOR UPDATE").find_by!(id: step_id, pipeline_id: pipeline.id)

          if step.terminal_coordination_status?
            recompute_pipeline_status_locked!(pipeline)
            next
          end

          next if pipeline.terminal? || pipeline.pending?

          if pipeline.canceling?
            record_draining_step_outcome(step, succeeded)
            recompute_pipeline_status_locked!(pipeline)
            next
          end

          if succeeded && step.halt_requested?
            handle_halt_execution_locked(pipeline, step)
            next
          end

          record_step_outcome(step, succeeded)
          propagate_halt_locked(pipeline, step) if !succeeded && pipeline.halt?
          unblock_downstream_steps_locked(pipeline, step)
          recompute_pipeline_status_locked!(pipeline)
        end
      end

      def try_enqueue_step(step_or_id)
        step_id = record_id(step_or_id)
        pipeline_id = pipeline_id_for_step(step_id)
        return false unless pipeline_id

        PipelineRecord.transaction do
          pipeline = PipelineRecord.lock("FOR UPDATE").find(pipeline_id)
          next false unless pipeline.running?

          enqueued = try_enqueue_step_locked(pipeline, step_id)
          recompute_pipeline_status_locked!(pipeline)
          enqueued
        end
      end

      def bulk_enqueue_steps(step_ids) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        step_ids = Array(step_ids)
        pipeline_id = pipeline_id_for_bulk_enqueue(step_ids)
        return if step_ids.empty? || pipeline_id.nil?

        PipelineRecord.transaction do
          pipeline = PipelineRecord.lock("FOR UPDATE").find(pipeline_id)
          next unless pipeline.running?

          steps = StepRecord.where(pipeline_id: pipeline.id, id: step_ids, coordination_status: "pending")
                            .where(good_job_id: nil)
                            .order(:id)
                            .lock("FOR UPDATE")
                            .to_a

          branch_steps, enqueueable_steps = steps.partition(&:branch_step?)
          failed_steps = bulk_enqueue_user_jobs_locked(pipeline, enqueueable_steps)

          failed_steps.each { |step, error| fail_step_with_error(step, error) }
          failed_steps.each { |failure| propagate_halt_locked(pipeline, failure.first) } if pipeline.halt?

          branch_steps.each { |step| try_enqueue_step_locked(pipeline, step.id) }
          recompute_pipeline_status_locked!(pipeline)
        end

        nil
      end

      def recompute_pipeline_status(pipeline_or_id)
        pipeline_id = record_id(pipeline_or_id)

        PipelineRecord.transaction do
          pipeline = PipelineRecord.lock("FOR UPDATE").find(pipeline_id)
          recompute_pipeline_status_locked!(pipeline)
          pipeline
        end
      end

      def dispatch_callbacks_once(pipeline_or_id, new_status)
        pipeline = pipeline_or_id.is_a?(PipelineRecord) ? pipeline_or_id : PipelineRecord.find(pipeline_or_id)

        PipelineRecord.transaction do
          rows_updated = PipelineRecord.where(id: pipeline.id, callbacks_dispatched_at: nil)
                                       .update_all(callbacks_dispatched_at: Time.current)

          next if rows_updated.zero?

          queue = pipeline.type.constantize.callback_queue_name
          PipelineCallbackJob.set(queue: queue).perform_later(pipeline.id, new_status.to_s)
        end
      end

      private

      def record_id(record_or_id)
        record_or_id.respond_to?(:id) ? record_or_id.id : record_or_id
      end

      def pipeline_id_for_step!(step_id)
        pipeline_id = pipeline_id_for_step(step_id)
        return pipeline_id if pipeline_id

        raise ActiveRecord::RecordNotFound, "Couldn't find GoodPipeline::StepRecord with 'id'=#{step_id}"
      end

      def pipeline_id_for_step(step_id)
        StepRecord.where(id: step_id).pick(:pipeline_id)
      end

      def pipeline_id_for_bulk_enqueue(step_ids)
        return if step_ids.empty?

        pipeline_ids = StepRecord.where(id: step_ids).distinct.pluck(:pipeline_id)
        raise ArgumentError, "bulk enqueue requires all steps to belong to the same pipeline" if pipeline_ids.many?

        pipeline_ids.first
      end

      def cancel_pending_steps_locked(pipeline)
        pipeline.steps.pending.update_all(coordination_status: "canceled", updated_at: Time.current)
      end

      def recompute_pipeline_status_locked!(pipeline)
        return if pipeline.terminal? || pipeline.pending?
        return if active_steps?(pipeline)

        transition_pipeline_to_terminal_locked!(pipeline, derive_terminal_status(pipeline))
      end

      def active_steps?(pipeline)
        pipeline.steps.where(coordination_status: ACTIVE_STEP_STATUSES).exists?
      end

      def transition_pipeline_to_terminal_locked!(pipeline, new_status)
        pipeline.transition_to!(new_status)
        dispatch_callbacks_once(pipeline, new_status)
        propagate_terminal_state_after_commit(pipeline.id)
      end

      def propagate_terminal_state_after_commit(pipeline_id)
        ActiveRecord.after_all_transactions_commit do
          pipeline = PipelineRecord.find_by(id: pipeline_id)
          ChainCoordinator.propagate_terminal_state(pipeline) if pipeline&.terminal?
        end
      end

      def record_draining_step_outcome(step, succeeded)
        if succeeded && step.halt_requested?
          step.transition_coordination_status_to!(:halted)
        else
          record_step_outcome(step, succeeded)
        end
      end

      def handle_halt_execution_locked(pipeline, step)
        step.transition_coordination_status_to!(:halted)
        pipeline.steps.pending.update_all(coordination_status: "skipped")
        recompute_pipeline_status_locked!(pipeline)
      end

      def record_step_outcome(step, succeeded)
        if succeeded
          step.transition_coordination_status_to!(:succeeded)
        else
          record_step_failure(step)
        end
      end

      def record_step_failure(step)
        metadata = FailureMetadata.extract(step)
        step.update_columns(
          coordination_status: "failed",
          updated_at: Time.current,
          error_class: metadata.error_class,
          error_message: metadata.error_message,
          attempts: metadata.attempts
        )
      end

      def propagate_halt_locked(pipeline, step)
        pipeline.update_column(:halt_triggered, true)
        skip_all_pending_steps(pipeline, except_dependents_of: step)
      end

      def skip_all_pending_steps(pipeline, except_dependents_of:)
        scope = pipeline.steps.pending

        if effective_failure_strategy(except_dependents_of) == :ignore
          exempt_ids = transitive_downstream_ids(except_dependents_of)
          scope = scope.where.not(id: exempt_ids.to_a) if exempt_ids.any?
        end

        scope.update_all(coordination_status: "skipped")
      end

      def transitive_downstream_ids(step)
        visited = Set.new
        queue = step.downstream_steps.pluck(:id)
        while (current_id = queue.shift)
          next if visited.include?(current_id)

          visited << current_id
          queue.concat(DependencyRecord.where(depends_on_step_id: current_id).pluck(:step_id))
        end
        visited
      end

      def unblock_downstream_steps_locked(pipeline, step)
        sql = <<~SQL
          UPDATE good_pipeline_steps
             SET pending_upstream_count = pending_upstream_count - 1
          WHERE id IN (
            SELECT step_id FROM good_pipeline_dependencies
             WHERE depends_on_step_id = $1
          )
            AND coordination_status = 'pending'
          RETURNING id, pending_upstream_count
        SQL

        any_enqueued = false
        StepRecord.connection.exec_query(sql, "SQL", [step.id]).each do |row|
          next unless row["pending_upstream_count"].zero?

          any_enqueued = true if try_enqueue_step_locked(pipeline, row["id"])
        end
        any_enqueued
      end

      def try_enqueue_step_locked(pipeline, step_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        return false unless pipeline.running?

        step = StepRecord.lock("FOR UPDATE").find_by(id: step_id, pipeline_id: pipeline.id)
        return false unless step&.pending?
        return false if step.good_job_id.present?

        begin
          downstream_ids = resolve_step(step)
          any_enqueued = step.enqueued?
        rescue ConfigurationError => error
          fail_step_with_error(step, error)
          propagate_halt_locked(pipeline, step) if pipeline.halt?
          downstream_ids = step.downstream_steps.pluck(:id)
          any_enqueued = false
        end

        downstream_ids&.each do |downstream_id|
          any_enqueued = true if try_enqueue_step_locked(pipeline, downstream_id)
        end

        any_enqueued
      end

      def resolve_step(locked_step) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        if should_skip?(locked_step)
          locked_step.transition_coordination_status_to!(:skipped)
          decrement_upstream_counts_for_terminal_step(locked_step.id)
          locked_step.downstream_steps.pluck(:id)
        elsif locked_step.branch_step? && all_upstreams_satisfied?(locked_step)
          BranchResolver.resolve(locked_step)
          decrement_upstream_counts_for_terminal_step(locked_step.id)
          locked_step.downstream_steps.pluck(:id)
        elsif BranchResolver.skipped_by_branch?(locked_step)
          locked_step.transition_coordination_status_to!(:skipped_by_branch)
          decrement_upstream_counts_for_terminal_step(locked_step.id)
          locked_step.downstream_steps.pluck(:id)
        else
          enqueue_user_job(locked_step) if all_upstreams_satisfied?(locked_step)
          nil
        end
      end

      def should_skip?(step)
        step.pending? && step.upstream_steps.any? { |upstream| permanently_unsatisfied?(upstream) }
      end

      def permanently_unsatisfied?(upstream)
        upstream.terminal_coordination_status? &&
          !upstream.succeeded? &&
          !upstream.halted? &&
          !upstream.skipped_by_branch? &&
          effective_failure_strategy(upstream) != :ignore
      end

      def decrement_upstream_counts_for_terminal_step(step_id)
        downstream_ids = DependencyRecord.where(depends_on_step_id: step_id).select(:step_id)
        StepRecord.where(id: downstream_ids, coordination_status: "pending")
                  .update_all("pending_upstream_count = pending_upstream_count - 1")
      end

      def all_upstreams_satisfied?(step)
        step.upstream_steps.all? do |upstream|
          upstream.succeeded? ||
            upstream.halted? ||
            upstream.skipped_by_branch? ||
            (upstream.failed? && effective_failure_strategy(upstream) == :ignore)
        end
      end

      def enqueue_user_job(step)
        batch = build_step_batch(step)
        good_job_id = nil
        batch.enqueue { good_job_id = enqueue_step_job(step) }
        step.update_columns(
          coordination_status: "enqueued",
          good_job_batch_id: batch.id,
          good_job_id: good_job_id,
          updated_at: Time.current
        )
      end

      def build_step_batch(step)
        batch = GoodJob::Batch.new
        batch.on_finish = "GoodPipeline::StepFinishedJob"
        batch.callback_queue_name = step.pipeline.type.constantize.coordination_queue_name
        batch.properties = { step_id: step.id, pipeline_id: step.pipeline_id }
        batch
      end

      def enqueue_step_job(step)
        job = step.job_class.constantize.new(**step.params.symbolize_keys)
        enqueued_job = job.enqueue(**step.enqueue_options.symbolize_keys)
        enqueued_job.provider_job_id || enqueued_job.job_id
      end

      def fail_step_with_error(step, error)
        step.transition_coordination_status_to!(:failed)
        step.update_columns(
          error_class: error.class.name,
          error_message: error.message
        )
      end

      def derive_terminal_status(pipeline)
        return :canceled if pipeline.canceling?

        has_failures = pipeline.steps.where(coordination_status: "failed").exists?

        return :succeeded unless has_failures
        return :halted if pipeline.halt_triggered?

        :failed
      end

      def bulk_enqueue_user_jobs_locked(pipeline, steps) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        return [] if steps.empty?

        batch_job_pairs = []
        step_metadata = {}
        failed_steps = []
        coordination_queue = pipeline.type.constantize.coordination_queue_name

        steps.each do |step|
          job_class = begin
            step.job_class.constantize
          rescue NameError => error
            failed_steps << [step, ConfigurationError.new(error.message)]
            next
          end

          batch = GoodJob::Batch.new
          batch.on_finish = "GoodPipeline::StepFinishedJob"
          batch.callback_queue_name = coordination_queue
          batch.properties = { step_id: step.id, pipeline_id: pipeline.id }

          active_job = job_class.new(**step.params.symbolize_keys)
          apply_enqueue_options(active_job, step.enqueue_options.symbolize_keys)

          batch_job_pairs << [batch, [active_job]]
          step_metadata[step.id] = { batch: batch, active_job: active_job }
        end

        GoodJob::Batch.enqueue_all(batch_job_pairs)

        now = Time.current
        steps_by_id = steps.index_by(&:id)
        step_metadata.each do |step_id, metadata|
          step = steps_by_id.fetch(step_id)
          step.update_columns(
            coordination_status: "enqueued",
            good_job_batch_id: metadata[:batch].id,
            good_job_id: metadata[:active_job].provider_job_id || metadata[:active_job].job_id,
            updated_at: now
          )
        end

        failed_steps
      end

      def apply_enqueue_options(active_job, options) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return if options.blank?

        if options[:good_job_labels] && active_job.respond_to?(:good_job_labels=)
          active_job.good_job_labels = Array(options[:good_job_labels])
        end

        if options.key?(:good_job_notify) && active_job.respond_to?(:good_job_notify=)
          active_job.good_job_notify = options[:good_job_notify]
        end

        active_job.queue_name = options[:queue].to_s if options[:queue]
        active_job.priority = options[:priority] if options[:priority]
        active_job.scheduled_at = Time.current + options[:wait] if options[:wait]
      end

      def effective_failure_strategy(step)
        step.on_failure_strategy&.to_sym || step.pipeline.on_failure_strategy.to_sym
      end
    end
  end
end
