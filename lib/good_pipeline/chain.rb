# frozen_string_literal: true

require "forwardable"

module GoodPipeline
  class Chain
    extend Forwardable

    attr_reader :pipeline_records

    def_delegators :first_pipeline_record,
                   :id, :status, :params, :type, :terminal?, :reload,
                   :steps, :dependencies, :halt_triggered?,
                   :callbacks_dispatched_at, :on_failure_strategy

    def initialize(pipeline_records)
      @pipeline_records = Array(pipeline_records)
    end

    def then(*arguments)
      instances = normalize_arguments(arguments).map do |pipeline_class, pipeline_params|
        pipeline_class.build(**pipeline_params)
      end

      Chain.new(register_downstreams(instances))
    end

    private

    def first_pipeline_record
      @pipeline_records.first
    end

    # One transaction owns the full fan-out registration: every downstream
    # graph, all incoming edges, and durable propagation for already-terminal
    # upstreams. The downstream rows are new and cannot be contended, so existing
    # pipeline locks are taken only after graph insertion and always by sorted id.
    def register_downstreams(instances) # rubocop:disable Metrics/MethodLength
      PipelineRecord.transaction do
        downstream_records = instances.map { |instance| Runner.call(instance, start: false) }
        locked_upstreams = lock_upstreams!
        edge_ids_by_upstream = create_incoming_edges(locked_upstreams, downstream_records)

        locked_upstreams.each do |upstream|
          next unless upstream.terminal?

          ChainCoordinator.reserve_terminal_state!(
            upstream,
            chain_ids: edge_ids_by_upstream.fetch(upstream.id)
          )
        end

        downstream_records
      end
    end

    # Settlement and cleanup take the same upstream pipeline-row lock. Thus
    # registration either commits its edge before settlement inspects outgoing
    # edges, or waits and observes terminal state before reserving its own job.
    def lock_upstreams!
      ids = @pipeline_records.filter_map(&:id).uniq.sort
      records = PipelineRecord.where(id: ids).order(:id).lock("FOR UPDATE").to_a
      return records if records.size == ids.size

      missing_ids = ids - records.map(&:id)
      raise ActiveRecord::RecordNotFound, "upstream pipeline(s) no longer exist: #{missing_ids.join(", ")}"
    end

    def create_incoming_edges(upstreams, downstreams)
      edge_ids_by_upstream = upstreams.to_h { |upstream| [upstream.id, []] }

      downstreams.each do |downstream|
        upstreams.each do |upstream|
          edge = ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: downstream)
          edge_ids_by_upstream.fetch(upstream.id) << edge.id
        end
      end

      edge_ids_by_upstream
    end

    def normalize_arguments(arguments)
      if arguments.first.is_a?(Array)
        arguments.map { |config| GoodPipeline.extract_pipeline_config(config) }
      else
        [GoodPipeline.extract_pipeline_config(arguments)]
      end
    end
  end
end
