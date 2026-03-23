# frozen_string_literal: true

module GoodPipeline
  class BranchBuilder
    attr_reader :arms

    def initialize(pipeline, branch_key, context_stack)
      @pipeline = pipeline
      @branch_key = branch_key
      @context_stack = context_stack
      @arms = Hash.new { |hash, key| hash[key] = [] }
    end

    def on(arm_value, &block)
      return @arms[arm_value] unless block

      @context_stack.push({ key: @branch_key, arm: arm_value, step_keys: [] })
      @pipeline.instance_eval(&block)
    ensure
      @arms[arm_value].concat(@context_stack.pop[:step_keys]) if block
    end
  end
end
