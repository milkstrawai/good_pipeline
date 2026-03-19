# frozen_string_literal: true

module GoodPipeline
  class StepDefinition
    attr_reader :key, :job_class, :params, :dependencies, :failure_strategy, :queue, :priority

    def initialize(key:, job_class:, params: {}, dependencies: [], failure_strategy: nil, queue: nil, priority: nil)
      @key = key
      @job_class = job_class
      @params = params.freeze
      @dependencies = Array(dependencies).freeze
      @failure_strategy = failure_strategy
      @queue = queue
      @priority = priority
      freeze
    end
  end
end
