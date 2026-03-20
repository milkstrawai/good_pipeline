# frozen_string_literal: true

module GoodPipeline
  module PipelinesHelper
    STATUS_BADGES = {
      "pending" => "\u25CB Pending",
      "running" => "\u25CF Running",
      "enqueued" => "\u25CF Enqueued",
      "succeeded" => "\u2713 Succeeded",
      "failed" => "\u2717 Failed",
      "halted" => "\u2298 Halted",
      "skipped" => "\u2298 Skipped"
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

    def mermaid_definition_diagram(pipeline)
      lines = ["graph TD"]
      pipeline.steps.each do |step|
        lines << "  #{step.key}(\"#{step.key}\"):::step"
      end
      pipeline.dependencies.each do |dependency|
        lines << "  #{dependency.depends_on_step.key} --> #{dependency.step.key}"
      end
      lines << "  classDef step fill:#4a90d9,color:#fff,stroke:#3a7bc8"
      lines.join("\n")
    end

    def mermaid_diagram(pipeline)
      lines = ["graph TD"]
      pipeline.steps.each do |step|
        lines << "  #{step.key}(\"#{step.key}\"):::#{step.coordination_status}"
      end
      pipeline.dependencies.each do |dependency|
        lines << "  #{dependency.depends_on_step.key} --> #{dependency.step.key}"
      end
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

    def mermaid_status_classes
      [
        "  classDef pending fill:#9e9e9e,color:#fff",
        "  classDef enqueued fill:#2196f3,color:#fff",
        "  classDef succeeded fill:#4caf50,color:#fff",
        "  classDef failed fill:#f44336,color:#fff",
        "  classDef skipped fill:#bdbdbd,color:#333"
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
