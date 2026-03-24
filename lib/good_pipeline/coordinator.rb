# frozen_string_literal: true

module GoodPipeline
  class Coordinator # rubocop:disable Metrics/ClassLength
    class << self
      def complete_step(step, succeeded:)
        return if step.terminal_coordination_status?

        record_step_outcome(step, succeeded)
        propagate_halt(step) if !succeeded && step.pipeline.halt?
        unblock_downstream_steps(step)
        recompute_pipeline_status(step.pipeline.reload)
      end

      def try_enqueue_step(step_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        skipped_downstream_ids = nil
        recompute_pipeline = nil

        StepRecord.transaction do
          locked_step = StepRecord.lock("FOR UPDATE SKIP LOCKED").find_by(id: step_id)
          return unless locked_step&.pending?
          return if locked_step.good_job_id.present?

          skipped_downstream_ids = resolve_step(locked_step)
        rescue ConfigurationError => error
          fail_step_with_error(locked_step, error)
          propagate_halt(locked_step) if locked_step.pipeline.halt?
          skipped_downstream_ids = locked_step.downstream_steps.pluck(:id)
          recompute_pipeline = locked_step.pipeline
        end

        skipped_downstream_ids&.each { |downstream_step_id| try_enqueue_step(downstream_step_id) }
        recompute_pipeline_status(recompute_pipeline.reload) if recompute_pipeline
      end

      def recompute_pipeline_status(pipeline)
        steps = pipeline.steps.reload

        return if steps.any? { |step| step.pending? || step.enqueued? }
        return if pipeline.terminal?

        new_status = derive_terminal_status(steps, pipeline)
        pipeline.transition_to!(new_status)
        dispatch_callbacks_once(pipeline, new_status)
        ChainCoordinator.propagate_terminal_state(pipeline)
      end

      def dispatch_callbacks_once(pipeline, new_status)
        PipelineRecord.transaction do
          locked = PipelineRecord.lock("FOR UPDATE").find(pipeline.id)
          return if locked.callbacks_dispatched_at.present?

          locked.update!(callbacks_dispatched_at: Time.current)
          PipelineCallbackJob.perform_later(locked.id, new_status.to_s)
        end
      end

      private

      def record_step_outcome(step, succeeded)
        StepRecord.transaction do
          if succeeded
            step.transition_coordination_status_to!(:succeeded)
          else
            record_step_failure(step)
          end
        end
      end

      def record_step_failure(step)
        metadata = FailureMetadata.extract(step)
        step.transition_coordination_status_to!(:failed)
        step.update_columns(
          error_class: metadata.error_class,
          error_message: metadata.error_message,
          attempts: metadata.attempts
        )
      end

      def propagate_halt(step)
        pipeline = step.pipeline
        StepRecord.transaction do
          pipeline.update_column(:halt_triggered, true)
          skip_all_pending_steps(pipeline, except_dependents_of: step)
        end
      end

      def unblock_downstream_steps(step)
        step.downstream_steps.each do |downstream_step|
          try_enqueue_step(downstream_step.id)
        end
      end

      def resolve_step(locked_step) # rubocop:disable Metrics/MethodLength
        if should_skip?(locked_step)
          locked_step.transition_coordination_status_to!(:skipped)
          locked_step.downstream_steps.pluck(:id)
        elsif locked_step.branch_step? && all_upstreams_satisfied?(locked_step)
          BranchResolver.resolve(locked_step)
          locked_step.downstream_steps.pluck(:id)
        elsif BranchResolver.skipped_by_branch?(locked_step)
          locked_step.transition_coordination_status_to!(:skipped_by_branch)
          locked_step.downstream_steps.pluck(:id)
        else
          enqueue_user_job(locked_step) if all_upstreams_satisfied?(locked_step)
          nil
        end
      end

      def enqueue_user_job(step)
        step.transition_coordination_status_to!(:enqueued)

        batch = build_step_batch(step)
        batch.enqueue { enqueue_step_job(step) }
        step.update_column(:good_job_batch_id, batch.id)
      end

      def build_step_batch(step)
        batch = GoodJob::Batch.new
        batch.on_finish = "GoodPipeline::StepFinishedJob"
        batch.properties = { step_id: step.id }
        batch
      end

      def enqueue_step_job(step)
        job = step.job_class.constantize.new(**step.params.symbolize_keys)
        enqueued_job = job.enqueue(**step.enqueue_options.symbolize_keys)
        step.update_column(:good_job_id, enqueued_job.provider_job_id || enqueued_job.job_id)
      end

      def derive_terminal_status(steps, pipeline)
        has_failures = steps.any?(&:failed?)

        return :succeeded unless has_failures
        return :halted if pipeline.halt_triggered?

        :failed
      end

      def all_upstreams_satisfied?(step)
        step.upstream_steps.all? do |upstream|
          upstream.succeeded? ||
            upstream.skipped_by_branch? ||
            (upstream.failed? && effective_failure_strategy(upstream) == :ignore)
        end
      end

      def should_skip?(step)
        step.pending? &&
          step.upstream_steps.any? { |upstream| permanently_unsatisfied?(upstream) }
      end

      def permanently_unsatisfied?(upstream)
        upstream.terminal_coordination_status? &&
          !upstream.succeeded? &&
          !upstream.skipped_by_branch? &&
          effective_failure_strategy(upstream) != :ignore
      end

      def skip_all_pending_steps(pipeline, except_dependents_of:)
        exempt_step_ids = if effective_failure_strategy(except_dependents_of) == :ignore
                            transitive_downstream_ids(except_dependents_of)
                          else
                            Set.new
                          end

        pipeline.steps.pending.find_each do |pending_step|
          next if exempt_step_ids.include?(pending_step.id)

          pending_step.transition_coordination_status_to!(:skipped)
        end
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

      def fail_step_with_error(step, error)
        step.transition_coordination_status_to!(:failed)
        step.update_columns(
          error_class: error.class.name,
          error_message: error.message
        )
      end

      def effective_failure_strategy(step)
        step.on_failure_strategy&.to_sym || step.pipeline.on_failure_strategy.to_sym
      end
    end
  end
end
