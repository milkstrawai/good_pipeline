# frozen_string_literal: true

module GoodPipeline
  class Coordinator # rubocop:disable Metrics/ClassLength
    class << self
      def complete_step(step, succeeded:) # rubocop:disable Metrics/MethodLength
        return if step.terminal_coordination_status?

        if succeeded && step.halt_requested?
          handle_halt_execution(step)
          return
        end

        record_step_outcome(step, succeeded)
        propagate_halt(step) if !succeeded && step.pipeline.halt?
        return if unblock_downstream_steps(step)

        pipeline = load_pipeline_with_active_check(step.pipeline_id)

        recompute_pipeline_status(
          pipeline,
          has_active_steps: pipeline["has_active_steps"],
          has_downstream_chains: pipeline["has_downstream_chains"]
        )
      end

      def try_enqueue_step(step_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        step_was_enqueued = false
        skipped_downstream_ids = nil
        recompute_pipeline = nil

        StepRecord.transaction do
          locked_step = StepRecord.lock("FOR UPDATE").find_by(id: step_id)
          return false unless locked_step&.pending?
          return false if locked_step.good_job_id.present?

          skipped_downstream_ids = resolve_step(locked_step)
          step_was_enqueued = skipped_downstream_ids.nil?
        rescue ConfigurationError => error
          fail_step_with_error(locked_step, error)
          propagate_halt(locked_step) if locked_step.pipeline.halt?
          skipped_downstream_ids = locked_step.downstream_steps.pluck(:id)
          recompute_pipeline = locked_step.pipeline
        end

        downstream_enqueued = false
        skipped_downstream_ids&.each { |id| downstream_enqueued = true if try_enqueue_step(id) }
        recompute_pipeline_status(recompute_pipeline.reload) if recompute_pipeline
        step_was_enqueued || downstream_enqueued
      end

      # Enqueues multiple steps in bulk using Batch.enqueue_all.
      # Intended for root steps during pipeline startup where no
      # concurrent enqueue risk exists and no upstream checks are needed.
      def bulk_enqueue_steps(step_ids)
        return if step_ids.empty?

        steps = StepRecord.where(id: step_ids, coordination_status: "pending")
                          .where(good_job_id: nil)
                          .to_a

        branch_steps, enqueueable_steps = steps.partition(&:branch_step?)

        bulk_enqueue_user_jobs(enqueueable_steps) if enqueueable_steps.any?

        branch_steps.each { |step| try_enqueue_step(step.id) }
      end

      def recompute_pipeline_status(pipeline, has_active_steps: nil, has_downstream_chains: nil) # rubocop:disable Metrics/MethodLength
        return if pipeline.terminal?

        active = if has_active_steps.nil?
                   pipeline.steps.where(coordination_status: %w[pending enqueued]).exists?
                 else
                   has_active_steps
                 end

        return if active

        new_status = derive_terminal_status(pipeline)
        pipeline.transition_to!(new_status)
        dispatch_callbacks_once(pipeline, new_status)
        ChainCoordinator.propagate_terminal_state(pipeline) unless has_downstream_chains == false
      end

      def dispatch_callbacks_once(pipeline, new_status)
        PipelineRecord.transaction do
          rows_updated = PipelineRecord.where(id: pipeline.id, callbacks_dispatched_at: nil)
                                       .update_all(callbacks_dispatched_at: Time.current)

          return if rows_updated.zero?

          queue = pipeline.type.constantize.callback_queue_name
          PipelineCallbackJob.set(queue: queue).perform_later(pipeline.id, new_status.to_s)
        end
      end

      private

      def handle_halt_execution(step)
        step.transition_coordination_status_to!(:halted)
        step.pipeline.steps.pending.update_all(coordination_status: "skipped")

        pipeline = load_pipeline_with_active_check(step.pipeline_id)

        recompute_pipeline_status(
          pipeline,
          has_active_steps: pipeline["has_active_steps"],
          has_downstream_chains: pipeline["has_downstream_chains"]
        )
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

      def propagate_halt(step)
        StepRecord.transaction do
          step.pipeline.update_column(:halt_triggered, true)
          skip_all_pending_steps(step.pipeline, except_dependents_of: step)
        end
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

      def unblock_downstream_steps(step)
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
          any_enqueued = true if row["pending_upstream_count"].zero? && try_enqueue_step(row["id"])
        end
        any_enqueued
      end

      def load_pipeline_with_active_check(pipeline_id)
        sql = <<~SQL.squish
          good_pipeline_pipelines.*,
          EXISTS(
            SELECT 1 FROM good_pipeline_steps
             WHERE pipeline_id = good_pipeline_pipelines.id
               AND coordination_status IN ('pending', 'enqueued')
          ) AS has_active_steps,
          EXISTS(
            SELECT 1 FROM good_pipeline_chains
             WHERE upstream_pipeline_id = good_pipeline_pipelines.id
          ) AS has_downstream_chains
        SQL

        PipelineRecord.select(sql).where(id: pipeline_id).first!
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
        batch.properties = { step_id: step.id }
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
        has_failures = pipeline.steps.where(coordination_status: "failed").exists?

        return :succeeded unless has_failures
        return :halted if pipeline.halt_triggered?

        :failed
      end

      def bulk_enqueue_user_jobs(steps) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength,Metrics/CyclomaticComplexity
        batch_job_pairs = []
        step_metadata = {}
        failed_steps = []
        coordination_queue = steps.first.pipeline.type.constantize.coordination_queue_name

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
          batch.properties = { step_id: step.id }

          active_job = job_class.new(**step.params.symbolize_keys)
          apply_enqueue_options(active_job, step.enqueue_options.symbolize_keys)

          batch_job_pairs << [batch, [active_job]]
          step_metadata[step.id] = { batch: batch, active_job: active_job }
        end

        StepRecord.transaction do
          GoodJob::Batch.enqueue_all(batch_job_pairs) if batch_job_pairs.any?

          now = Time.current
          step_metadata.each do |step_id, metadata|
            StepRecord.where(id: step_id).update_all(
              coordination_status: "enqueued",
              good_job_batch_id: metadata[:batch].id,
              good_job_id: metadata[:active_job].provider_job_id || metadata[:active_job].job_id,
              updated_at: now
            )
          end
        end
      ensure
        failed_steps.each do |step, error|
          fail_step_with_error(step, error)
          propagate_halt(step) if step.pipeline.halt?
        end
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
