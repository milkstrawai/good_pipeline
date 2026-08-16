# frozen_string_literal: true

module GoodPipeline
  class ChainCoordinator
    class << self
      # Reserves one durable GoodJob actor per outgoing chain edge. Callers must
      # invoke this while holding the terminal upstream row lock and inside the
      # transaction that writes the terminal status. Immediate GoodJob enqueue
      # then makes the status and every propagation row one atomic commit.
      #
      # `chain_ids` is supplied by Chain#then because it already has the newly
      # inserted edges. Settlement callers omit it and load every committed edge
      # while their upstream lock closes registration races.
      def reserve_terminal_state!(pipeline, chain_ids: nil)
        validate_reservation!(pipeline)
        edge_ids = terminal_edge_ids(pipeline, chain_ids)
        return if edge_ids.empty?

        ExecutionConfiguration.validate_enqueue!(ChainPropagationJob)
        queue_name = coordination_queue_for(pipeline)
        edge_ids.each { |edge_id| enqueue_edge!(edge_id, queue_name) }
      end

      # Executes one immutable edge handoff. A missing edge means retention has
      # already removed a relationship whose downstream was no longer pending;
      # it is therefore a deliberate no-op. While a downstream is pending,
      # cleanup preserves both its edges and terminal upstream state.
      def propagate_edge(chain_record_id)
        downstream_pipeline_id = ChainRecord.where(id: chain_record_id).pick(:downstream_pipeline_id)
        return if downstream_pipeline_id.nil?

        try_start_downstream(downstream_pipeline_id)
      end

      private

      def validate_reservation!(pipeline)
        unless PipelineRecord.connection.transaction_open?
          raise ArgumentError, "chain propagation must be reserved inside the terminal-state transaction"
        end
        raise ArgumentError, "chain propagation requires a terminal pipeline" unless pipeline.terminal?
      end

      def terminal_edge_ids(pipeline, chain_ids)
        ids = chain_ids || ChainRecord.where(upstream_pipeline_id: pipeline.id).order(:id).pluck(:id)
        ids.compact.uniq.sort
      end

      def enqueue_edge!(edge_id, queue_name)
        job = ChainPropagationJob.new(edge_id)
        result = job.enqueue(queue: queue_name)
        return if result && job.provider_job_id.present?

        raise job.enqueue_error if job.enqueue_error

        raise ConfigurationError,
              "GoodPipeline could not synchronously persist chain propagation for edge #{edge_id}; " \
              "terminal settlement was rolled back"
      end

      # Only the downstream row is locked. Upstream statuses are read, never
      # locked, after the propagation job and its upstream terminal status have
      # committed atomically. A still-running sibling is safe: its own terminal
      # transaction will create another edge job. Avoiding upstream locks here
      # also prevents a downstream->upstream inversion against Chain#then.
      def try_start_downstream(pipeline_id) # rubocop:disable Metrics/MethodLength
        PipelineRecord.transaction do
          # A blocking lock, deliberately. Concurrent edge deliveries serialize
          # here; the first transition changes `pending`, and every duplicate
          # becomes a no-op after acquiring the lock.
          locked = PipelineRecord.lock("FOR UPDATE").find_by(id: pipeline_id)
          return unless locked&.pending?

          if should_skip_downstream?(locked)
            locked.transition_to!(:skipped)
            Coordinator.dispatch_callbacks_once(locked, :skipped)
            # A skipped pipeline is terminal too. Its outgoing propagation must
            # be committed with that transition rather than recursively handed
            # off in process memory.
            reserve_terminal_state!(locked)
          elsif all_upstreams_succeeded?(locked)
            start_pipeline(locked)
          end
        end
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

      # Stored class names may outlive deploys. Propagation itself only needs
      # record identifiers, so a missing class must not roll back terminal state;
      # route it through the globally configured coordination queue instead.
      def coordination_queue_for(pipeline)
        pipeline_class = begin
          pipeline.type.constantize
        rescue NameError
          nil
        end

        if pipeline_class.respond_to?(:coordination_queue_name)
          pipeline_class.coordination_queue_name
        else
          GoodPipeline.coordination_queue_name
        end
      end
    end
  end
end
