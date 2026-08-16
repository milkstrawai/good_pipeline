# frozen_string_literal: true

module GoodPipeline
  class Error < StandardError; end

  class InvalidPipelineError < Error; end

  class InvalidTransition < Error; end

  class ConfigurationError < Error; end

  # Raised only after a pipeline graph has committed and root startup then
  # encounters an unexpected error. The immutable identifier lets API and UI
  # callers recover the execution without treating it as if creation failed.
  class PipelineStartError < Error
    attr_reader :pipeline_id, :original_error

    def initialize(pipeline_id:, original_error:)
      @pipeline_id = pipeline_id
      @original_error = original_error
      super("pipeline #{pipeline_id} was created but could not fully start (#{original_error.class})")
    end
  end

  # Internal signal for a deterministic failure at a user-code/configuration
  # boundary. Coordinator unwraps original_error when recording step metadata,
  # so the dashboard retains the application exception's class and message.
  class DeterministicStepStartError < Error
    attr_reader :original_error

    def initialize(original_error)
      @original_error = original_error
      super("deterministic step startup failed (#{original_error.class})")
    end
  end
end
