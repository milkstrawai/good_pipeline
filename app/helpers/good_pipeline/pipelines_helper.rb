# frozen_string_literal: true

module GoodPipeline
  module PipelinesHelper # rubocop:disable Metrics/ModuleLength
    STATUS_BADGES = {
      "pending" => "\u25CB Pending",
      "running" => "\u25CF Running",
      "enqueued" => "\u25CF Enqueued",
      "succeeded" => "\u2713 Succeeded",
      "failed" => "\u2717 Failed",
      "halted" => "\u2298 Halted",
      "skipped" => "\u2298 Skipped",
      "skipped_by_branch" => "\u2298 Skipped (branch)"
    }.freeze

    def status_badge(status)
      label = STATUS_BADGES.fetch(status.to_s, status.to_s)
      tag.span(label, class: "badge badge-#{status}")
    end

    def humanized_type(pipeline_type)
      pipeline_type.to_s.underscore.titleize
    end

    def relative_time_tag(datetime)
      return "" unless datetime

      tag.time(relative_time(datetime),
               datetime: datetime.iso8601,
               title: datetime.strftime("%Y-%m-%d %H:%M:%S %Z"))
    end

    def pipeline_duration(pipeline)
      return nil unless pipeline.terminal?

      total = (pipeline.updated_at - pipeline.created_at).to_f
      return "< 1s" if total < 1

      minutes, seconds = total.to_i.divmod(60)
      hours, minutes = minutes.divmod(60)
      [("#{hours}h" if hours.positive?), ("#{minutes}m" if minutes.positive?), "#{seconds}s"].compact.join(" ")
    end

    def mermaid_definition_diagram(pipeline) # rubocop:disable Metrics/MethodLength
      lines = ["graph TD"]
      pipeline.steps.each do |step|
        lines << if step.branch_step?
                   "  #{step.key}{\"#{step.key}\"}:::branch"
                 else
                   "  #{step.key}(\"#{step.key}\"):::step"
                 end
      end
      mermaid_edges(pipeline, lines)
      mermaid_terminal_node(pipeline, lines)
      lines << "  classDef step fill:#4a90d9,color:#fff,stroke:#3a7bc8"
      lines << "  classDef branch fill:#ff9800,color:#fff,stroke:#f57c00"
      lines << "  classDef terminal fill:#1a1a2e,color:#fff,stroke:#1a1a2e"
      lines.join("\n")
    end

    def mermaid_diagram(pipeline) # rubocop:disable Metrics/MethodLength
      lines = ["graph TD"]
      pipeline.steps.each do |step|
        lines << if step.branch_step?
                   "  #{step.key}{\"#{step.key}\"}:::branch"
                 else
                   "  #{step.key}(\"#{step.key}\"):::#{step.coordination_status}"
                 end
      end
      mermaid_edges(pipeline, lines)
      mermaid_terminal_node(pipeline, lines)
      lines.concat(mermaid_status_classes)
      lines.join("\n")
    end

    def good_job_step_url(step)
      return nil unless step.good_job_id

      mount_path = good_job_mount_path
      return nil unless mount_path

      "#{mount_path}/jobs/#{step.good_job_id}"
    end

    def relative_time(datetime)
      return "" unless datetime

      distance = (Time.current - datetime).to_i
      case distance
      when 0..59 then "just now"
      when 60..3599 then "#{distance / 60}m ago"
      when 3600..86_399 then "#{distance / 3600}h ago"
      else "#{distance / 86_400}d ago"
      end
    end

    def truncated_params(pipeline_params)
      return "" if pipeline_params.blank?

      json = pipeline_params.to_json
      json.length > 100 ? "#{json[0..97]}..." : json
    end

    private

    def mermaid_edges(pipeline, lines)
      pipeline.dependencies.each do |dependency|
        upstream = dependency.depends_on_step
        step = dependency.step
        lines << if upstream.branch_step? && step.branch_arm_step?
                   "  #{upstream.key} -->|#{step.branch_arm}| #{step.key}"
                 else
                   "  #{upstream.key} --> #{step.key}"
                 end
      end
    end

    # Add an "End" node connected from all terminal steps and empty branch arms.
    def mermaid_terminal_node(pipeline, lines) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      has_downstream_ids = pipeline.dependencies.to_set { |dependency| dependency.depends_on_step.id }
      terminal_steps = pipeline.steps.reject { |step| has_downstream_ids.include?(step.id) }

      lines << "  end_node((\" \")):::terminal"
      terminal_steps.each { |step| lines << "  #{step.key} --> end_node" }

      # Empty arms connect to post-branch steps, or End if there are none
      arm_step_keys_by_branch = pipeline.steps.select(&:branch_arm_step?).group_by(&:branch_key)

      pipeline.steps.select(&:branch_step?).each do |branch_step|
        next if branch_step.empty_arms.blank?

        # Find steps that depend on this branch's arm steps but aren't arm steps of this branch
        arm_keys = (arm_step_keys_by_branch[branch_step.key] || []).to_set(&:key)
        targets = pipeline.steps.select do |step|
          !arm_keys.include?(step.key) && step.upstream_steps.any? { |upstream| arm_keys.include?(upstream.key) }
        end

        branch_step.empty_arms.each do |arm_name|
          if targets.any?
            targets.each { |target| lines << "  #{branch_step.key} -->|#{arm_name}| #{target.key}" }
          else
            lines << "  #{branch_step.key} -->|#{arm_name}| end_node"
          end
        end
      end
    end

    def mermaid_status_classes
      [
        "  classDef pending fill:#9e9e9e,color:#fff",
        "  classDef enqueued fill:#2196f3,color:#fff",
        "  classDef succeeded fill:#4caf50,color:#fff",
        "  classDef failed fill:#f44336,color:#fff",
        "  classDef skipped fill:#bdbdbd,color:#333",
        "  classDef skipped_by_branch fill:#bdbdbd,color:#333",
        "  classDef branch fill:#ff9800,color:#fff,stroke:#f57c00",
        "  classDef terminal fill:#1a1a2e,color:#fff,stroke:#1a1a2e"
      ]
    end

    def good_job_mount_path
      return nil unless defined?(GoodJob::Engine)

      route = Rails.application.routes.routes.detect do |r|
        r.app.respond_to?(:app) && r.app.app == GoodJob::Engine
      end

      return nil unless route

      route.path.spec.to_s.delete_suffix("(.:format)")
    end
  end
end
