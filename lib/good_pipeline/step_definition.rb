# frozen_string_literal: true

module GoodPipeline
  class StepDefinition
    attr_reader :key, :job_class, :params, :dependencies, :on_failure, :queue, :priority

    def initialize(key:, job_class:, params: {}, dependencies: [], on_failure: nil, queue: nil, priority: nil)
      @key = key
      @job_class = job_class
      @params = params.freeze
      @dependencies = Array(dependencies).freeze
      @on_failure = on_failure
      @queue = queue
      @priority = priority
      freeze
    end
  end
end
