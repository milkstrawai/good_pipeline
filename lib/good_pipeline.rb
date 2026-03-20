# frozen_string_literal: true

require_relative "good_pipeline/version"
require_relative "good_pipeline/errors"
require_relative "good_pipeline/step_definition"
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
      pipeline_class = config[0]
      params = config.fetch(1, {}).fetch(:with, {})
      instance = pipeline_class.build(**params)
      Runner.call(instance)
    end

    Chain.new(pipeline_records)
  end
end
