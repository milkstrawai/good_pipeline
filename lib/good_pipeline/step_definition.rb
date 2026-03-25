# frozen_string_literal: true

module GoodPipeline
  class StepDefinition
    SUPPORTED_ENQUEUE_OPTIONS = %i[queue priority wait good_job_labels good_job_notify].freeze

    attr_reader :key,
                :job_class,
                :params,
                :dependencies,
                :failure_strategy,
                :enqueue_options,
                :branch_key,
                :branch_arm,
                :decides,
                :empty_arms

    def initialize( # rubocop:disable Metrics/MethodLength
      key:,
      job_class:,
      params: EMPTY_HASH,
      dependencies: EMPTY_ARRAY,
      failure_strategy: nil,
      enqueue_options: EMPTY_HASH,
      branch_key: nil,
      branch_arm: nil,
      decides: nil,
      empty_arms: EMPTY_ARRAY
    )
      @key = key
      @job_class = job_class
      @params = params.freeze
      @dependencies = Array(dependencies).freeze
      validate_failure_strategy!(failure_strategy)
      @failure_strategy = failure_strategy
      validate_enqueue_options!(enqueue_options)
      @enqueue_options = enqueue_options.freeze
      @branch_key = branch_key
      @branch_arm = branch_arm
      @decides = decides
      @empty_arms = Array(empty_arms).freeze
      freeze
    end

    private

    def validate_failure_strategy!(strategy)
      return if strategy.nil?

      valid = GoodPipeline::Pipeline::VALID_FAILURE_STRATEGIES
      return if valid.include?(strategy)

      raise ConfigurationError,
            "invalid step failure strategy :#{strategy}, must be one of #{valid.map { |s| ":#{s}" }.join(", ")}"
    end

    def validate_enqueue_options!(options)
      return if options.empty?

      unsupported = options.keys.map(&:to_sym) - SUPPORTED_ENQUEUE_OPTIONS
      return if unsupported.empty?

      raise ConfigurationError, "unsupported enqueue options: #{unsupported.join(", ")}"
    end
  end
end
