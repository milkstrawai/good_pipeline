# frozen_string_literal: true

module GoodPipeline
  class Coordinator # rubocop:disable Metrics/ClassLength
    def self.complete_step(step, succeeded:)
      return if step.terminal_coordination_status?

      record_step_outcome(step, succeeded)
      propagate_halt(step) if !succeeded && step.pipeline.halt?
      unblock_downstream_steps(step)
      recompute_pipeline_status(step.pipeline.reload)
    end

    def self.record_step_outcome(step, succeeded)
      StepRecord.transaction do
        if succeeded
          step.transition_coordination_status_to!(:succeeded)
        else
          record_step_failure(step)
        end
      end
    end

    def self.record_step_failure(step)
      metadata = FailureMetadata.extract(step)
      step.transition_coordination_status_to!(:failed)
      step.update_columns(
        error_class: metadata.error_class,
        error_message: metadata.error_message,
        attempts: metadata.attempts
      )
    end

    def self.propagate_halt(step)
      pipeline = step.pipeline
      StepRecord.transaction do
        pipeline.update_column(:halt_triggered, true)
        skip_all_pending_steps(pipeline, except_dependents_of: step)
      end
    end

    def self.unblock_downstream_steps(step)
      step.downstream_steps.each do |downstream_step|
        try_enqueue_step(downstream_step.id)
      end
    end

    def self.try_enqueue_step(step_id)
      skipped_downstream_ids = nil

      StepRecord.transaction do
        locked_step = StepRecord.lock("FOR UPDATE SKIP LOCKED").find_by(id: step_id)
        return unless locked_step&.pending?
        return if locked_step.good_job_id.present?

        skipped_downstream_ids = resolve_step(locked_step)
      end

      skipped_downstream_ids&.each { |downstream_step_id| try_enqueue_step(downstream_step_id) }
    end

    def self.resolve_step(locked_step)
      if should_skip?(locked_step)
        locked_step.transition_coordination_status_to!(:skipped)
        locked_step.downstream_steps.pluck(:id)
      else
        enqueue_user_job(locked_step) if all_upstreams_satisfied?(locked_step)
        nil
      end
    end

    def self.enqueue_user_job(step)
      step.transition_coordination_status_to!(:enqueued)

      batch = build_step_batch(step)
      batch.enqueue { enqueue_step_job(step) }
      step.update_column(:good_job_batch_id, batch.id)
    end

    def self.build_step_batch(step)
      batch = GoodJob::Batch.new
      batch.on_finish = "GoodPipeline::StepFinishedJob"
      batch.properties = { step_id: step.id }
      batch
    end

    def self.enqueue_step_job(step)
      job = step.job_class.constantize.new(**step.params.symbolize_keys)
      enqueued_job = job.enqueue(**step.enqueue_options.symbolize_keys)
      step.update_column(:good_job_id, enqueued_job.provider_job_id || enqueued_job.job_id)
    end

    def self.recompute_pipeline_status(pipeline)
      steps = pipeline.steps.reload

      return if steps.any? { |step| step.pending? || step.enqueued? }
      return if pipeline.terminal?

      new_status = derive_terminal_status(steps, pipeline)
      pipeline.transition_to!(new_status)
      dispatch_callbacks_once(pipeline, new_status)
      ChainCoordinator.propagate_terminal_state(pipeline)
    end

    def self.derive_terminal_status(steps, pipeline)
      has_failures = steps.any?(&:failed?)

      return :succeeded unless has_failures
      return :halted if pipeline.halt_triggered?

      :failed
    end

    def self.dispatch_callbacks_once(pipeline, new_status)
      PipelineRecord.transaction do
        locked = PipelineRecord.lock("FOR UPDATE").find(pipeline.id)
        return if locked.callbacks_dispatched_at.present?

        locked.update!(callbacks_dispatched_at: Time.current)
        PipelineCallbackJob.perform_later(locked.id, new_status.to_s)
      end
    end

    # --- Private helpers ---

    def self.all_upstreams_satisfied?(step)
      step.upstream_steps.all? do |upstream|
        upstream.succeeded? ||
          (upstream.failed? && effective_strategy(upstream) == :ignore)
      end
    end

    def self.should_skip?(step)
      step.pending? &&
        step.upstream_steps.any? { |upstream| permanently_unsatisfied?(upstream) }
    end

    def self.permanently_unsatisfied?(upstream)
      upstream.terminal_coordination_status? &&
        !upstream.succeeded? &&
        effective_strategy(upstream) != :ignore
    end

    def self.skip_all_pending_steps(pipeline, except_dependents_of:)
      exempt_step_ids = if effective_strategy(except_dependents_of) == :ignore
                          except_dependents_of.downstream_steps.pluck(:id)
                        else
                          []
                        end

      pipeline.steps.pending.find_each do |pending_step|
        next if exempt_step_ids.include?(pending_step.id)

        pending_step.transition_coordination_status_to!(:skipped)
      end
    end

    def self.effective_strategy(step)
      step.on_failure_strategy&.to_sym || step.pipeline.on_failure_strategy.to_sym
    end

    private_class_method :record_step_outcome, :record_step_failure,
                         :propagate_halt, :unblock_downstream_steps,
                         :all_upstreams_satisfied?, :should_skip?, :permanently_unsatisfied?,
                         :skip_all_pending_steps, :effective_strategy,
                         :enqueue_user_job, :build_step_batch, :enqueue_step_job,
                         :derive_terminal_status, :resolve_step
  end
end
