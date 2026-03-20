# frozen_string_literal: true

module GoodPipeline
  class Pipeline
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

      # Internal: reconstructs a minimal Pipeline for callback dispatch.
      def for_callback(pipeline_record)
        instance = allocate
        instance.instance_variable_set(:@pipeline_record, pipeline_record)
        instance.instance_variable_set(:@params, pipeline_record.params.symbolize_keys.freeze)
        instance.instance_variable_set(:@step_definitions, [].freeze)
        instance.instance_variable_set(:@steps_by_key, {}.freeze)
        instance.instance_variable_set(:@root_steps, [].freeze)
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

    def initialize(**kwargs)
      @params = kwargs.freeze
      @step_definitions = []
      @building = true
      configure(**kwargs)
      GraphValidator.validate!(@step_definitions)
      @step_definitions.freeze
      @building = false
      @steps_by_key = @step_definitions.to_h { |step| [step.key, step] }.freeze
      @root_steps = @step_definitions.select { |step| step.dependencies.empty? }.freeze
      freeze
    end

    private

    def configure(**_kwargs)
      raise NotImplementedError, "#{self.class} must implement #configure"
    end

    def run(key, job_class, with: {}, after: [], failure_strategy: nil, queue: nil, priority: nil)
      raise ConfigurationError, "run can only be called inside configure" unless @building

      @step_definitions << StepDefinition.new(
        key: key,
        job_class: job_class,
        params: with,
        dependencies: after,
        failure_strategy: failure_strategy,
        queue: queue,
        priority: priority
      )
    end
  end
end
