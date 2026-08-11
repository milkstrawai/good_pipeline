# frozen_string_literal: true

module GoodPipeline
  module Dashboard
    # Immutable, normalized dashboard query-string state.
    class FilterSet
      TIMES = { "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days, "all" => nil }.freeze
      STATUSES = %w[all running succeeded failed halted skipped].freeze
      DEFAULT_TIME = "all"

      attr_reader :status, :pipeline_type, :time, :query, :page, :expanded

      def self.from_params(params)
        status = value(params, :status).to_s
        time = value(params, :time).to_s

        new(
          status: STATUSES.include?(status) ? status : "all",
          pipeline_type: presence(value(params, :pipeline_type)),
          time: TIMES.key?(time) ? time : DEFAULT_TIME,
          query: value(params, :q).to_s,
          page: [value(params, :page).to_i, 1].max,
          expanded: presence(value(params, :expanded))
        )
      end

      def self.value(params, key)
        value = params[key]
        value.nil? ? params[key.to_s] : value
      rescue KeyError
        nil
      end
      private_class_method :value

      def self.presence(value)
        string = value.to_s
        string.strip.empty? ? nil : string
      end
      private_class_method :presence

      def initialize(status:, pipeline_type:, time:, query:, page:, expanded:)
        @status = status.to_s.dup.freeze
        @pipeline_type = frozen_optional_string(pipeline_type)
        @time = time.to_s.dup.freeze
        @query = query.to_s.dup.freeze
        @page = [page.to_i, 1].max
        @expanded = frozen_optional_string(expanded)
        freeze
      end

      def time_cutoff(now = Time.current)
        delta = TIMES[time]
        delta ? now - delta : nil
      end

      def all_statuses? = status == "all"
      def all_time? = time == "all"

      def to_h
        {
          status: status,
          pipeline_type: pipeline_type,
          time: time,
          q: query,
          page: page,
          expanded: expanded
        }
      end

      private

      def frozen_optional_string(value)
        value.to_s.dup.freeze unless value.nil?
      end
    end
  end
end
