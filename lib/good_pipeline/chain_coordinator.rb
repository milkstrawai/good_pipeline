# frozen_string_literal: true

module GoodPipeline
  class ChainCoordinator
    def self.propagate_terminal_state(pipeline)
      pipeline.downstream_pipelines.each do |downstream_pipeline|
        try_start_downstream(downstream_pipeline.id)
      end
    end

    def self.try_start_downstream(pipeline_id) # rubocop:disable Metrics/MethodLength
      skipped_downstream_ids = nil

      PipelineRecord.transaction do
        locked = PipelineRecord.lock("FOR UPDATE SKIP LOCKED").find_by(id: pipeline_id)
        return unless locked&.pending?

        if should_skip_downstream?(locked)
          locked.transition_to!(:skipped)
          Coordinator.dispatch_callbacks_once(locked, :skipped)
          skipped_downstream_ids = locked.downstream_pipelines.pluck(:id)
        elsif all_upstreams_succeeded?(locked)
          start_pipeline(locked)
        end
      end

      skipped_downstream_ids&.each { |downstream_id| try_start_downstream(downstream_id) }
    end

    def self.should_skip_downstream?(pipeline)
      pipeline.upstream_pipelines.any? do |upstream|
        upstream.failed? || upstream.halted? || upstream.skipped?
      end
    end

    def self.all_upstreams_succeeded?(pipeline)
      pipeline.upstream_pipelines.all?(&:succeeded?)
    end

    def self.start_pipeline(pipeline_record)
      pipeline_record.transition_to!(:running)

      root_step_ids = pipeline_record.steps.where.missing(:upstream_dependencies).pluck(:id)

      root_step_ids.each do |step_id|
        Coordinator.try_enqueue_step(step_id)
      end
    end

    private_class_method :try_start_downstream, :all_upstreams_succeeded?,
                         :should_skip_downstream?, :start_pipeline
  end
end
