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

    def then(*arguments) # rubocop:disable Metrics/MethodLength
      configs = normalize_arguments(arguments)
      downstream_records = []

      configs.each do |pipeline_class, pipeline_params|
        instance = pipeline_class.build(**pipeline_params)
        downstream_record = Runner.call(instance, start: false)
        downstream_records << downstream_record

        @pipeline_records.each do |upstream_record|
          ChainRecord.create!(
            upstream_pipeline: upstream_record,
            downstream_pipeline: downstream_record
          )
        end
      end

      propagate_if_upstream_already_terminal

      Chain.new(downstream_records)
    end

    private

    def first_pipeline_record
      @pipeline_records.first
    end

    def propagate_if_upstream_already_terminal
      @pipeline_records.each do |upstream_record|
        ChainCoordinator.propagate_terminal_state(upstream_record) if upstream_record.reload.terminal?
      end
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
