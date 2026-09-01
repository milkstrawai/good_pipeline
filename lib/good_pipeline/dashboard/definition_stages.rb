# frozen_string_literal: true

module GoodPipeline
  module Dashboard
    # Structural stage aggregation for definitions, which have no execution
    # statuses or GoodJob timing geometry.
    class DefinitionStages
      Stage = Struct.new(:stage, :level, :n, :job_classes, :role, keyword_init: true) do
        def label = n > 1 ? "#{stage} \u00D7#{n}" : stage
      end

      def initialize(steps:, dependencies:)
        @steps = Topology.ordered_steps(steps)
        @dependencies = Array(dependencies)
      end

      def call # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        pairs = Topology.dependency_pairs(@steps, @dependencies)
        levels = Topology.levels(@steps, pairs)
        downstream_tokens = pairs.to_set(&:first)
        groups = {}
        order = []

        @steps.each do |step|
          level = levels.fetch(Topology.token_for(step), 0)
          stage = Topology.label_for(step).sub(/_\d+\z/, "")
          group_key = "#{stage}@#{level}"
          unless groups.key?(group_key)
            groups[group_key] = { stage: stage, level: level, steps: [] }
            order << group_key
          end
          groups[group_key][:steps] << step
        end

        order.map do |group_key|
          group = groups.fetch(group_key)
          steps = group.fetch(:steps)
          Stage.new(
            stage: group.fetch(:stage),
            level: group.fetch(:level),
            n: steps.length,
            job_classes: steps.map { |step| step.job_class.to_s }.uniq.freeze,
            role: role_for(steps, downstream_tokens)
          ).freeze
        end
      end

      private

      def role_for(steps, downstream_tokens)
        return :barrier if steps.any? { |step| Topology.barrier_step?(step) }
        return :branch if steps.any? { |step| Topology.branch_step?(step) }
        return :terminal if steps.all? { |step| !downstream_tokens.include?(Topology.token_for(step)) }

        :step
      end
    end
  end
end
