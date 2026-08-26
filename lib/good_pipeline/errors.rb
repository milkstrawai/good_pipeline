# frozen_string_literal: true

module GoodPipeline
  class Error < StandardError; end

  class InvalidPipelineError < Error; end

  class InvalidTransition < Error; end

  class ConfigurationError < Error; end

  class CancellationConflict < Error
    attr_reader :pipeline_id, :status

    def initialize(pipeline_id:, status:)
      @pipeline_id = pipeline_id
      @status = status.to_s

      super("cannot cancel pipeline '#{pipeline_id}' from '#{@status}' status")
    end
  end
end
