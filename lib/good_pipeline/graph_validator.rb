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
      check_duplicate_keys!
      build_steps_by_key!
      check_self_dependencies!
      check_unknown_references!
      check_cycles!
    end

    private

    def check_empty_pipeline!
      raise InvalidPipelineError, "pipeline has no steps" if @step_definitions.empty?
    end

    def check_duplicate_keys!
      seen = {}
      @step_definitions.each do |step|
        raise InvalidPipelineError, "duplicate step key :#{step.key}" if seen.key?(step.key)

        seen[step.key] = true
      end
    end

    def build_steps_by_key!
      @steps_by_key = @step_definitions.to_h { |step| [step.key, step] }
    end

    def check_self_dependencies!
      @steps_by_key.each_value do |step|
        raise InvalidPipelineError, "step :#{step.key} depends on itself" if step.dependencies.include?(step.key)
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
      CycleDetector.check!(@steps_by_key, build_forward_edges)
    end

    def build_forward_edges
      edges = Hash.new { |h, k| h[k] = [] }
      @steps_by_key.each_value do |step|
        step.dependencies.each do |dependency_key|
          edges[dependency_key] << step.key
        end
      end
      edges
    end
  end
end
