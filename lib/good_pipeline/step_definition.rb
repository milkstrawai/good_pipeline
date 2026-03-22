# frozen_string_literal: true

module GoodPipeline
  class StepDefinition
    SUPPORTED_ENQUEUE_OPTIONS = %i[queue priority wait good_job_labels good_job_notify].freeze

    attr_reader :key, :job_class, :params, :dependencies, :failure_strategy, :enqueue_options

    def initialize(key:, job_class:, params: {}, dependencies: [], failure_strategy: nil, enqueue_options: {})
      @key = key
      @job_class = job_class
      @params = params.freeze
      @dependencies = Array(dependencies).freeze
      @failure_strategy = failure_strategy
      validate_enqueue_options!(enqueue_options)
      @enqueue_options = enqueue_options.freeze
      freeze
    end

    private

    def validate_enqueue_options!(options)
      unsupported = options.keys.map(&:to_sym) - SUPPORTED_ENQUEUE_OPTIONS
      return if unsupported.empty?

      raise ConfigurationError, "unsupported enqueue options: #{unsupported.join(", ")}"
    end
  end
end
