# frozen_string_literal: true

module GoodPipeline
  class Pipeline # rubocop:disable Metrics/ClassLength
    BRANCH_JOB_CLASS = "GoodPipeline::Branch"
    VALID_FAILURE_STRATEGIES = %i[halt continue ignore].freeze
    DSL_ATTRIBUTES = %i[description failure_strategy on_complete on_success on_failure].freeze

    # --- Class-level DSL ---

    class << self
      def inherited(subclass)
        super
        DSL_ATTRIBUTES.each do |attribute|
          subclass.instance_variable_set(:"@#{attribute}", instance_variable_get(:"@#{attribute}"))
        end
      end

      def description(text = :__unset__)
        return @description if text == :__unset__

        @description = text
      end

      def failure_strategy(strategy = :__unset__)
        return @failure_strategy || :halt if strategy == :__unset__

        unless VALID_FAILURE_STRATEGIES.include?(strategy)
          valid = VALID_FAILURE_STRATEGIES.map { |valid_strategy| ":#{valid_strategy}" }.join(", ")
          raise ConfigurationError, "invalid failure strategy :#{strategy}, must be one of #{valid}"
        end

        @failure_strategy = strategy
      end

      def on_complete(method_name = :__unset__)
        return @on_complete if method_name == :__unset__

        @on_complete = method_name
      end

      def on_success(method_name = :__unset__)
        return @on_success if method_name == :__unset__

        @on_success = method_name
      end

      def on_failure(method_name = :__unset__)
        return @on_failure if method_name == :__unset__

        @on_failure = method_name
      end

      alias build new

      def run(**)
        instance = new(**)
        pipeline_record = Runner.call(instance)
        Chain.new(pipeline_record)
      end

      # Internal: reconstructs a minimal Pipeline instance for runtime method calls
      # (callbacks, branch decisions). Skips configure/validation.
      def reconstruct(pipeline_record)
        instance = allocate
        instance.instance_variable_set(:@pipeline_record, pipeline_record)
        instance.instance_variable_set(:@params, pipeline_record.params.symbolize_keys.freeze)
        instance.instance_variable_set(:@step_definitions, [].freeze)
        instance.instance_variable_set(:@steps_by_key, {}.freeze)
        instance.instance_variable_set(:@root_steps, [].freeze)
        instance.instance_variable_set(:@branch_aliases, {}.freeze)
        instance
      end
    end

    # --- Instance API ---

    attr_reader :step_definitions, :steps_by_key, :root_steps, :params, :pipeline_record

    def description
      self.class.description
    end

    def failure_strategy
      self.class.failure_strategy
    end

    def on_complete_callback = self.class.on_complete
    def on_success_callback = self.class.on_success
    def on_failure_callback = self.class.on_failure

    def initialize(**kwargs) # rubocop:disable Metrics/MethodLength
      @params = kwargs.freeze
      @step_definitions = []
      @branch_aliases = {}
      @branch_context_stack = []
      @building = true
      configure(**kwargs)
      GraphValidator.validate!(@step_definitions)
      @step_definitions.freeze
      @branch_aliases.freeze
      @building = false
      @steps_by_key = @step_definitions.to_h { |step| [step.key, step] }.freeze
      @root_steps = @step_definitions.select { |step| step.dependencies.empty? }.freeze
      freeze
    end

    private

    def configure(**_kwargs)
      raise NotImplementedError, "#{self.class} must implement #configure"
    end

    def run(key, job_class, with: {}, after: [], on_failure: nil, enqueue: {}) # rubocop:disable Metrics/MethodLength
      raise ConfigurationError, "run can only be called inside configure" unless @building

      expanded_after = expand_branch_aliases(after)

      branch_key = nil
      branch_arm = nil
      if @branch_context_stack.any?
        context = @branch_context_stack.last
        branch_key = context[:key]
        branch_arm = context[:arm]
        expanded_after = ([context[:key]] + expanded_after).uniq
        context[:step_keys] << key
      end

      @step_definitions << StepDefinition.new(
        key: key,
        job_class: job_class,
        params: with,
        dependencies: expanded_after,
        failure_strategy: on_failure,
        enqueue_options: enqueue,
        branch_key: branch_key,
        branch_arm: branch_arm
      )
    end

    def branch(key, by:, after: [], &) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      raise ConfigurationError, "branch can only be called inside configure" unless @building
      raise ConfigurationError, "nested branches are not supported" if @branch_context_stack.any?

      branch_dependencies = expand_branch_aliases(after)

      builder = BranchBuilder.new(self, key, @branch_context_stack)
      builder.instance_eval(&)

      raise InvalidPipelineError, "branch :#{key} must have at least 1 arm" if builder.arms.empty?

      empty_arm_names = builder.arms.select { |_, step_keys| step_keys.empty? }.keys

      # Create the branch step (sentinel job class, decides set)
      @step_definitions << StepDefinition.new(
        key: key,
        job_class: BRANCH_JOB_CLASS,
        dependencies: branch_dependencies,
        decides: by,
        empty_arms: empty_arm_names
      )

      @branch_aliases[key] = exit_step_keys(builder.arms)
    end

    # Exit steps are the last steps in each arm — no other arm step depends on them.
    # Called by `branch` to compute which step keys the alias expands to.
    def exit_step_keys(arms)
      arms.flat_map do |_, arm_step_keys|
        arm_step_keys.reject do |key|
          @step_definitions.any? do |step_definition|
            arm_step_keys.include?(step_definition.key) && step_definition.dependencies.include?(key)
          end
        end
      end
    end

    # Called by `run` to replace branch keys in `after:` with exit step keys.
    # NOTE: Single-level expansion only. If nested branches are added in the future,
    # this must become recursive to expand inner branch aliases.
    def expand_branch_aliases(dependencies)
      Array(dependencies).flat_map { |dependency| @branch_aliases.fetch(dependency, [dependency]) }
    end
  end
end
