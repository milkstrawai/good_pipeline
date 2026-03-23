# frozen_string_literal: true

require_relative "good_pipeline/version"
require_relative "good_pipeline/errors"
require_relative "good_pipeline/step_definition"
require_relative "good_pipeline/branch_builder"
require_relative "good_pipeline/cycle_detector"
require_relative "good_pipeline/graph_validator"
require_relative "good_pipeline/pipeline"
require_relative "good_pipeline/failure_metadata"
require_relative "good_pipeline/coordinator"
require_relative "good_pipeline/chain_coordinator"
require_relative "good_pipeline/runner"
require_relative "good_pipeline/chain"
require_relative "good_pipeline/engine" if defined?(Rails::Engine)

module GoodPipeline
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

  def self.cleanup_preserved_pipelines(older_than:)
    pipeline_ids = PipelineRecord.where(status: PipelineRecord::TERMINAL_STATUSES)
                                 .where("updated_at < ?", older_than)
                                 .pluck(:id)
    return if pipeline_ids.empty?

    DependencyRecord.where(pipeline_id: pipeline_ids).delete_all
    StepRecord.where(pipeline_id: pipeline_ids).delete_all
    ChainRecord.where(upstream_pipeline_id: pipeline_ids)
               .or(ChainRecord.where(downstream_pipeline_id: pipeline_ids))
               .delete_all
    PipelineRecord.where(id: pipeline_ids).delete_all
  end
end
