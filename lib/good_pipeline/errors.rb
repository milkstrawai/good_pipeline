# frozen_string_literal: true

module GoodPipeline
  class Error < StandardError; end

  class InvalidPipelineError < Error; end

  class InvalidTransition < Error; end

  class ConfigurationError < Error; end
end
