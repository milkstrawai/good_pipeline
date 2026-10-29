# frozen_string_literal: true

module GoodPipeline
  class ChainCoordinator
    class << self
      def propagate_terminal_state(pipeline)
        pipeline.downstream_pipelines.each do |downstream_pipeline|
          try_start_downstream(downstream_pipeline.id)
        end
      end

      private

      def try_start_downstream(pipeline_id) # rubocop:disable Metrics/MethodLength
        skipped_downstream_ids = nil

        PipelineRecord.transaction do
          locked = PipelineRecord.lock("FOR UPDATE").find_by(id: pipeline_id)
          return unless locked&.pending?

          if should_skip_downstream?(locked)
            locked.transition_to!(:skipped)
            Coordinator.dispatch_callbacks_once(locked, :skipped)
            skipped_downstream_ids = locked.downstream_pipelines.pluck(:id)
          elsif all_upstreams_satisfied?(locked)
            start_pipeline(locked)
          end
        end

        skipped_downstream_ids&.each { |downstream_id| try_start_downstream(downstream_id) }
      end

      def should_skip_downstream?(pipeline)
        pipeline.upstream_pipelines.any? do |upstream|
          upstream.terminal? && !upstream_satisfied?(upstream)
        end
      end

      def upstream_satisfied?(upstream)
        upstream.succeeded? || (upstream.failed? && upstream.ignore?)
      end

      def all_upstreams_satisfied?(pipeline)
        pipeline.upstream_pipelines.all? { |upstream| upstream_satisfied?(upstream) }
      end

      def start_pipeline(pipeline_record)
        pipeline_record.transition_to!(:running)
        root_step_ids = pipeline_record.steps.where.missing(:upstream_dependencies).pluck(:id)
        Coordinator.bulk_enqueue_steps(root_step_ids)
      end
    end
  end
end
