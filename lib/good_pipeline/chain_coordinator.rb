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
          # A blocking lock, deliberately. With SKIP LOCKED, a propagation
          # holding this row while reading a sibling upstream as still-running
          # combines with that sibling skipping past the held lock — both exit
          # without starting the downstream, stranding it. Blocking is
          # deadlock-free here: each propagation transaction locks exactly one
          # downstream row and takes no other pipeline locks while holding it
          # (the skip cascade below runs after this transaction commits).
          locked = PipelineRecord.lock("FOR UPDATE").find_by(id: pipeline_id)
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

      def should_skip_downstream?(pipeline)
        pipeline.upstream_pipelines.any? do |upstream|
          upstream.failed? || upstream.halted? || upstream.skipped?
        end
      end

      def all_upstreams_succeeded?(pipeline)
        pipeline.upstream_pipelines.all?(&:succeeded?)
      end

      def start_pipeline(pipeline_record)
        pipeline_record.transition_to!(:running)
        root_step_ids = pipeline_record.steps.where.missing(:upstream_dependencies).pluck(:id)
        Coordinator.bulk_enqueue_steps(root_step_ids)
      end
    end
  end
end
