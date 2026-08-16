# frozen_string_literal: true

require_relative "good_pipeline/version"
require_relative "good_pipeline/constants"
require_relative "good_pipeline/errors"
require_relative "good_pipeline/execution_configuration"
require_relative "good_pipeline/step_definition"
require_relative "good_pipeline/branch_builder"
require_relative "good_pipeline/cycle_detector"
require_relative "good_pipeline/graph_validator"
require_relative "good_pipeline/dashboard"
require_relative "good_pipeline/pipeline"
require_relative "good_pipeline/failure_metadata"
require_relative "good_pipeline/branch_resolver"
require_relative "good_pipeline/coordinator"
require_relative "good_pipeline/chain_coordinator"
require_relative "good_pipeline/runner"
require_relative "good_pipeline/haltable"
require_relative "good_pipeline/chain"
require_relative "good_pipeline/engine" if defined?(Rails::Engine)

module GoodPipeline
  DEFAULT_COORDINATION_QUEUE_NAME = "good_pipeline_coordination"
  DEFAULT_CALLBACK_QUEUE_NAME = "good_pipeline_callbacks"

  class << self
    attr_writer :coordination_queue_name, :callback_queue_name

    def coordination_queue_name
      @coordination_queue_name || DEFAULT_COORDINATION_QUEUE_NAME
    end

    def callback_queue_name
      @callback_queue_name || DEFAULT_CALLBACK_QUEUE_NAME
    end
  end

  def self.run(*pipeline_configs)
    pipeline_records = pipeline_configs.map do |config|
      pipeline_class, pipeline_params = extract_pipeline_config(config)
      instance = pipeline_class.build(**pipeline_params)
      Runner.call(instance)
    end

    Chain.new(pipeline_records)
  end

  # Internal: parses [PipelineClass, { with: { ... } }] config format.
  def self.extract_pipeline_config(config)
    [config[0], config.fetch(1, {}).fetch(:with, {})]
  end

  # Public compatibility entry point used by the engine initializer. All boot
  # and enqueue-boundary semantics live in one testable component.
  def self.validate_good_job_configuration!
    ExecutionConfiguration.validate_boot!
  end

  def self.cleanup_preserved_pipelines(older_than:) # rubocop:disable Metrics/MethodLength
    PipelineRecord.transaction do
      # Candidates are selected under lock with both predicates re-applied so
      # they are authoritative at deletion time: a pipeline that left a terminal
      # status after being identified no longer matches, and a row held by a
      # concurrent claim (e.g. a settlement in flight) is skipped, deferring its
      # pruning to the next sweep.
      # A terminal upstream remains the authoritative status input for every
      # pending chained downstream. Preserve it (and therefore its edge) until
      # durable propagation moves the downstream out of pending; otherwise
      # cleanup could make a fan-in appear satisfied with fewer prerequisites.
      unresolved_upstream_ids = ChainRecord.where(
        downstream_pipeline_id: PipelineRecord.where(status: "pending").select(:id)
      ).select(:upstream_pipeline_id)

      pipeline_ids = PipelineRecord.where(status: PipelineRecord::TERMINAL_STATUSES)
                                   .where("updated_at < ?", older_than)
                                   .where.not(id: unresolved_upstream_ids)
                                   .order(:id)
                                   .lock("FOR UPDATE SKIP LOCKED")
                                   .pluck(:id)
      next if pipeline_ids.empty?

      delete_pipeline_graph(pipeline_ids)
    end
  end

  def self.delete_pipeline_graph(pipeline_ids)
    DependencyRecord.where(pipeline_id: pipeline_ids).delete_all
    StepRecord.where(pipeline_id: pipeline_ids).delete_all
    ChainRecord.where(upstream_pipeline_id: pipeline_ids)
               .or(ChainRecord.where(downstream_pipeline_id: pipeline_ids))
               .delete_all
    PipelineRecord.where(id: pipeline_ids).delete_all
  end
  private_class_method :delete_pipeline_graph
end
