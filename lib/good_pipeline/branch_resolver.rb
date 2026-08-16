# frozen_string_literal: true

module GoodPipeline
  class BranchResolver
    class << self
      def resolve(step)
        pipeline_class = resolve_pipeline_class(step)
        decides_method = step.decides.to_sym

        validate_decision_method!(pipeline_class, decides_method, step)

        instance = pipeline_class.reconstruct(step.pipeline)
        result = instance.send(decides_method).to_s

        validate_result!(step, result)

        step.update_column(:branch, step.branch.merge("branch_result" => result))
        step.transition_coordination_status_to!(:succeeded)
      end

      def skipped_by_branch?(step)
        return false unless step.branch_arm_step?

        branch_step = step.pipeline.steps.find_by(key: step.branch_key)
        return false unless branch_step&.branch_result

        branch_step.branch_result != step.branch_arm
      end

      private

      # Normalized so the coordinator's failure handler records a missing
      # pipeline class on the step instead of the NameError escaping
      # StepFinishedJob.
      def resolve_pipeline_class(step)
        step.pipeline.type.constantize
      rescue NameError => error
        raise ConfigurationError, error.message
      end

      def validate_decision_method!(pipeline_class, decides_method, step)
        return if pipeline_class.method_defined?(decides_method) ||
                  pipeline_class.private_method_defined?(decides_method)

        raise ConfigurationError,
              "Pipeline #{step.pipeline.type} does not define decision method :#{decides_method}"
      end

      def validate_result!(step, result) # rubocop:disable Metrics/AbcSize
        declared_arms = step.pipeline.steps
                            .select { |pipeline_step| pipeline_step.branch_key == step.key.to_s }
                            .filter_map(&:branch_arm)
                            .uniq
        declared_arms.concat(Array(step.empty_arms))

        return if declared_arms.include?(result)

        raise ConfigurationError,
              "branch :#{step.key} decision returned \"#{result}\", " \
              "but only #{declared_arms.map { |arm| ":#{arm}" }.join(", ")} are declared"
      end
    end
  end
end
