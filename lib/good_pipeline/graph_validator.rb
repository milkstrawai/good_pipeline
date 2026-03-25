# frozen_string_literal: true

module GoodPipeline
  class GraphValidator
    def self.validate!(step_definitions)
      new(step_definitions).validate!
    end

    def initialize(step_definitions)
      @step_definitions = step_definitions
    end

    def validate!
      check_empty_pipeline!
      build_index!
      check_unknown_references!
      check_cycles!
      @steps_by_key
    end

    private

    def check_empty_pipeline!
      raise InvalidPipelineError, "pipeline has no steps" if @step_definitions.empty?
    end

    def build_index! # rubocop:disable Metrics/AbcSize
      @steps_by_key = {}
      @forward_edges = Hash.new { |h, k| h[k] = [] }

      @step_definitions.each do |step|
        raise InvalidPipelineError, "duplicate step key :#{step.key}" if @steps_by_key.key?(step.key)

        step.dependencies.each do |dependency_key|
          raise InvalidPipelineError, "step :#{step.key} depends on itself" if dependency_key == step.key

          @forward_edges[dependency_key] << step.key
        end

        @steps_by_key[step.key] = step
      end
    end

    def check_unknown_references!
      @steps_by_key.each_value do |step|
        step.dependencies.each do |dependency_key|
          unless @steps_by_key.key?(dependency_key)
            raise InvalidPipelineError, "step :#{step.key} references unknown dependency :#{dependency_key}"
          end
        end
      end
    end

    def check_cycles!
      CycleDetector.check!(@steps_by_key, @forward_edges)
    end
  end
end
