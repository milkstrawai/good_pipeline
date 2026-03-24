# frozen_string_literal: true

module GoodPipeline
  class MermaidDiagramBuilder
    DEFINITION_CLASSES = [
      "  classDef step fill:#4a90d9,color:#fff,stroke:#3a7bc8",
      "  classDef branch fill:#ff9800,color:#fff,stroke:#f57c00",
      "  classDef terminal fill:#1a1a2e,color:#fff,stroke:#1a1a2e"
    ].freeze

    STATUS_CLASSES = [
      "  classDef pending fill:#9e9e9e,color:#fff",
      "  classDef enqueued fill:#2196f3,color:#fff",
      "  classDef succeeded fill:#4caf50,color:#fff",
      "  classDef failed fill:#f44336,color:#fff",
      "  classDef skipped fill:#bdbdbd,color:#333",
      "  classDef skipped_by_branch fill:#bdbdbd,color:#333",
      "  classDef branch fill:#ff9800,color:#fff,stroke:#f57c00",
      "  classDef terminal fill:#1a1a2e,color:#fff,stroke:#1a1a2e"
    ].freeze

    def initialize(pipeline)
      @pipeline = pipeline
    end

    def definition_diagram
      lines = ["graph TD"]
      append_step_nodes(lines) { |step| step.branch_step? ? "branch" : "step" }
      append_edges(lines)
      append_terminal_node(lines)
      lines.concat(DEFINITION_CLASSES)
      lines.join("\n")
    end

    def status_diagram
      lines = ["graph TD"]
      append_step_nodes(lines) { |step| step.branch_step? ? "branch" : step.coordination_status }
      append_edges(lines)
      append_terminal_node(lines)
      lines.concat(STATUS_CLASSES)
      lines.join("\n")
    end

    private

    def append_step_nodes(lines)
      @pipeline.steps.each do |step|
        css_class = yield(step)
        lines << if step.branch_step?
                   "  #{step.key}{\"#{step.key}\"}:::#{css_class}"
                 else
                   "  #{step.key}(\"#{step.key}\"):::#{css_class}"
                 end
      end
    end

    def append_edges(lines)
      @pipeline.dependencies.each do |dependency|
        upstream = dependency.depends_on_step
        downstream = dependency.step
        lines << if upstream.branch_step? && downstream.branch_arm_step?
                   "  #{upstream.key} -->|#{downstream.branch_arm}| #{downstream.key}"
                 else
                   "  #{upstream.key} --> #{downstream.key}"
                 end
      end
    end

    def append_terminal_node(lines)
      has_downstream_ids = @pipeline.dependencies.to_set { |dependency| dependency.depends_on_step.id }
      terminal_steps = @pipeline.steps.reject { |step| has_downstream_ids.include?(step.id) }

      lines << "  end_node((\" \")):::terminal"
      terminal_steps.each { |step| lines << "  #{step.key} --> end_node" }

      append_empty_arm_edges(lines)
    end

    def append_empty_arm_edges(lines) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      arm_step_keys_by_branch = @pipeline.steps.select(&:branch_arm_step?).group_by(&:branch_key)

      @pipeline.steps.select(&:branch_step?).each do |branch_step|
        next if branch_step.empty_arms.blank?

        targets = find_post_branch_targets(branch_step, arm_step_keys_by_branch)

        branch_step.empty_arms.each do |arm_name|
          if targets.any?
            targets.each { |target| lines << "  #{branch_step.key} -->|#{arm_name}| #{target.key}" }
          else
            lines << "  #{branch_step.key} -->|#{arm_name}| end_node"
          end
        end
      end
    end

    def find_post_branch_targets(branch_step, arm_step_keys_by_branch)
      arm_keys = (arm_step_keys_by_branch[branch_step.key] || []).to_set(&:key)

      @pipeline.steps.select do |step|
        !arm_keys.include?(step.key) && step.upstream_steps.any? { |upstream| arm_keys.include?(upstream.key) }
      end
    end
  end
end
