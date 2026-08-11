# frozen_string_literal: true

module GoodPipeline
  module PipelinesHelper # rubocop:disable Metrics/ModuleLength
    STATUS_META = {
      "pending" => { label: "pending", glyph: "\u25CB", var: "--st-pending", variable: "--st-pending" },
      "running" => { label: "running", glyph: "\u25CF", var: "--st-running", variable: "--st-running" },
      "enqueued" => { label: "enqueued", glyph: "\u25CF", var: "--st-running", variable: "--st-running" },
      "succeeded" => { label: "succeeded", glyph: "\u2713", var: "--st-succeeded", variable: "--st-succeeded" },
      "failed" => { label: "failed", glyph: "\u2717", var: "--st-failed", variable: "--st-failed" },
      "halted" => { label: "halted", glyph: "\u2298", var: "--st-halted", variable: "--st-halted" },
      "skipped" => { label: "skipped", glyph: "\u2298", var: "--st-skipped", variable: "--st-skipped" },
      "skipped_by_branch" => {
        label: "skipped\u00B7br", glyph: "\u2298", var: "--st-skipped", variable: "--st-skipped"
      }
    }.transform_values(&:freeze).freeze

    STATUS_STACK_ORDER = %w[
      succeeded failed halted enqueued running pending skipped skipped_by_branch
    ].freeze

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

    def status_pill(status)
      status = status.to_s
      meta = status_meta(status)
      tag.span("#{meta[:glyph]} #{meta[:label]}", class: "gp-status-pill gp-status-#{status}")
    end

    def status_meta(status)
      status = status.to_s
      STATUS_META.fetch(status) do
        { label: status, glyph: "", var: "--st-pending", variable: "--st-pending" }.freeze
      end
    end

    def humanized_type(pipeline_type)
      pipeline_type.to_s.safe_constantize&.display_name || pipeline_type.to_s.underscore.titleize
    end

    def short_type(pipeline_type)
      humanized_type(pipeline_type).sub(/\s*Pipeline\z/, "")
    end

    def relative_time_tag(datetime)
      return "" unless datetime

      tag.time(relative_time(datetime),
               datetime: datetime.iso8601,
               title: absolute_time(datetime))
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
      MermaidDiagramBuilder.new(pipeline).definition_diagram
    end

    def mermaid_diagram(pipeline)
      MermaidDiagramBuilder.new(pipeline).status_diagram
    end

    def mermaid_edge_count(pipeline)
      MermaidDiagramBuilder.new(pipeline).edge_count
    end

    def mermaid_overflow?(pipeline)
      MermaidDiagramBuilder.new(pipeline).overflow?
    end

    def good_job_step_url(step)
      return nil unless step.good_job_id

      mount_path = good_job_mount_path
      return nil unless mount_path

      "#{mount_path}/jobs/#{step.good_job_id}"
    end

    def relative_time(datetime, now: Time.current)
      return "" unless datetime

      distance = [(now - datetime).to_i, 0].max
      case distance
      when 0..59 then "#{distance}s ago"
      when 60..3599 then "#{distance / 60}m ago"
      when 3600..86_399 then "#{distance / 3600}h ago"
      else "#{distance / 86_400}d ago"
      end
    end

    def absolute_time(datetime)
      return "" unless datetime

      utc_time = datetime.respond_to?(:getutc) ? datetime.getutc : datetime.in_time_zone("UTC")
      utc_time.strftime("%Y-%m-%d %H:%M:%SZ")
    end

    def format_duration(seconds)
      return "\u2014" if seconds.nil?

      total = [seconds.to_i, 0].max
      return "#{total}s" if total < 60

      minutes, remaining_seconds = total.divmod(60)
      return "#{minutes}m #{remaining_seconds}s" if total < 3_600

      hours, remaining_minutes = minutes.divmod(60)
      "#{hours}h #{remaining_minutes}m"
    end

    def format_number(number)
      number.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end

    def step_progress(steps)
      steps = Array(steps)
      [steps.count { |step| step.coordination_status.to_s == "succeeded" }, steps.length]
    end

    def step_progress_title(steps)
      done, total = step_progress(steps)
      "#{done} succeeded of #{total} total steps"
    end

    def truncated_params(pipeline_params)
      return "" if pipeline_params.blank?

      json = pipeline_params.to_json
      json.length > 100 ? "#{json[0..97]}..." : json
    end

    private

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
