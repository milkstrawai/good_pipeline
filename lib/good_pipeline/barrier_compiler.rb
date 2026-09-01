# frozen_string_literal: true

module GoodPipeline
  class BarrierCompiler
    KEY_PREFIX = "__good_pipeline_barrier_"
    private_constant :KEY_PREFIX

    def self.call(step_definitions, markers)
      new(step_definitions, markers).call
    end

    def initialize(step_definitions, markers)
      @step_definitions = step_definitions
      @markers = markers
    end

    def call
      validate_markers!
      GraphValidator.validate!(@step_definitions)

      phases = split_phases
      barrier_keys = generated_barrier_keys
      validate_generated_key_collisions!(barrier_keys)
      validate_dependency_directions!(phases)

      compile(phases, barrier_keys)
    end

    private

    def validate_markers!
      raise InvalidPipelineError, "barrier must follow at least one step" if @markers.first&.zero?
      if @markers.each_cons(2).any? { |left, right| left == right }
        raise InvalidPipelineError, "consecutive barriers are not supported"
      end
      return unless @markers.last == @step_definitions.length

      raise InvalidPipelineError, "barrier must be followed by at least one step"
    end

    def split_phases
      [0, *@markers, @step_definitions.length].each_cons(2).map do |from, to|
        @step_definitions[from...to]
      end
    end

    def generated_barrier_keys
      @markers.each_index.map { |index| :"#{KEY_PREFIX}#{index + 1}" }
    end

    def validate_generated_key_collisions!(barrier_keys)
      existing_keys = @step_definitions.to_set { |step| step.key.to_s }
      collision = barrier_keys.find { |key| existing_keys.include?(key.to_s) }
      return unless collision

      raise InvalidPipelineError, "step key :#{collision} is reserved for a generated barrier"
    end

    def validate_dependency_directions!(phases)
      phase_by_key = phase_index_by_key(phases)

      phases.each_with_index do |phase, phase_index|
        phase.each { |step| validate_dependency_direction!(step, phase_index, phase_by_key) }
      end
    end

    def phase_index_by_key(phases)
      phases.each_with_index.with_object({}) do |(phase, phase_index), index|
        phase.each { |step| index[step.key] = phase_index }
      end
    end

    def validate_dependency_direction!(step, phase_index, phase_by_key)
      later_dependency = step.dependencies.find { |key| phase_by_key.fetch(key) > phase_index }
      return unless later_dependency

      raise InvalidPipelineError,
            "step :#{step.key} cannot depend on later barrier phase step :#{later_dependency}"
    end

    def compile(phases, barrier_keys)
      phases.each_with_index.flat_map do |phase, index|
        previous_barrier_key = barrier_keys[index - 1] if index.positive?
        compiled_phase = add_previous_barrier_to_entries(phase, previous_barrier_key)
        next compiled_phase if index == phases.length - 1

        compiled_phase + [build_barrier(barrier_keys.fetch(index), compiled_phase.map(&:key))]
      end
    end

    def add_previous_barrier_to_entries(phase, previous_barrier_key)
      return phase unless previous_barrier_key

      phase_keys = phase.to_set(&:key)
      phase.map do |step|
        next step if step.dependencies.any? { |key| phase_keys.include?(key) }

        step.with_dependencies(step.dependencies + [previous_barrier_key])
      end
    end

    def build_barrier(key, dependencies)
      StepDefinition.new(key: key, job_class: BARRIER_JOB_CLASS, dependencies: dependencies)
    end
  end
end
