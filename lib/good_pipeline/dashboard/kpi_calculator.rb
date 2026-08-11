# frozen_string_literal: true

module GoodPipeline
  module Dashboard
    # Computes the global/type-scoped KPI strip. Status, search, and the feed's
    # selected time window intentionally do not affect these aggregates.
    class KpiCalculator # rubocop:disable Metrics/ClassLength
      Result = Struct.new(
        :running_now,
        :last_24h,
        :failed_7d,
        :failed_prior_7d,
        :p50,
        :p95,
        :enqueued_steps,
        :sparkline,
        keyword_init: true
      ) do
        alias_method :prior_failed_7d, :failed_prior_7d
        alias_method :p50_duration, :p50
        alias_method :p95_duration, :p95
        alias_method :buckets, :sparkline
      end

      def initialize(pipeline_type: nil, now: Time.current, connection: nil, cache: default_cache)
        @pipeline_type = pipeline_type.to_s.empty? ? nil : pipeline_type.to_s
        @now = now
        @connection = connection
        @cache = cache
      end

      def call
        return calculate unless @cache

        @cache.fetch(cache_key, expires_in: 30.seconds) { calculate }
      end

      private

      def calculate # rubocop:disable Metrics/MethodLength
        values = aggregate
        Result.new(
          running_now: integer(values, "running_now"),
          last_24h: integer(values, "last_24h"),
          failed_7d: integer(values, "failed_7d"),
          failed_prior_7d: integer(values, "failed_prior_7d"),
          p50: number_or_nil(values, "p50"),
          p95: number_or_nil(values, "p95"),
          enqueued_steps: integer(values, "enqueued_steps"),
          sparkline: Sparkline.new(
            pipeline_type: @pipeline_type,
            now: @now,
            connection: connection
          ).buckets.freeze
        ).freeze
      end

      def aggregate # rubocop:disable Metrics/AbcSize
        connection.select_one(<<~SQL)
          SELECT
            COUNT(*) FILTER (WHERE p.status = 'running') AS running_now,
            COUNT(*) FILTER (WHERE p.created_at > #{quote(@now - 24.hours)}) AS last_24h,
            COUNT(*) FILTER (
              WHERE p.status = 'failed' AND p.created_at > #{quote(@now - 7.days)}
            ) AS failed_7d,
            COUNT(*) FILTER (
              WHERE p.status = 'failed'
                AND p.created_at > #{quote(@now - 14.days)}
                AND p.created_at <= #{quote(@now - 7.days)}
            ) AS failed_prior_7d,
            percentile_cont(0.5) WITHIN GROUP (
              ORDER BY EXTRACT(EPOCH FROM (p.updated_at - p.created_at))
            ) FILTER (
              WHERE p.status IN ('succeeded', 'failed', 'halted', 'skipped')
                AND p.created_at > #{quote(@now - 7.days)}
            ) AS p50,
            percentile_cont(0.95) WITHIN GROUP (
              ORDER BY EXTRACT(EPOCH FROM (p.updated_at - p.created_at))
            ) FILTER (
              WHERE p.status IN ('succeeded', 'failed', 'halted', 'skipped')
                AND p.created_at > #{quote(@now - 7.days)}
            ) AS p95,
            (
              SELECT COUNT(*)
              FROM #{step_table} s
              JOIN #{pipeline_table} p2 ON p2.id = s.pipeline_id
              WHERE s.coordination_status = 'enqueued' #{type_scope("p2")}
            ) AS enqueued_steps
          FROM #{pipeline_table} p
          WHERE (p.status = 'running' OR p.created_at > #{quote(@now - 14.days)})
            #{type_scope("p")}
        SQL
      end

      def type_scope(table_alias)
        @pipeline_type ? "AND #{table_alias}.type = #{quote(@pipeline_type)}" : ""
      end

      def integer(values, key)
        (values[key] || values[key.to_sym]).to_i
      end

      def number_or_nil(values, key)
        value = values[key] || values[key.to_sym]
        value&.to_f
      end

      def cache_key
        ["good_pipeline", "kpis", GoodPipeline::VERSION, @pipeline_type]
      end

      def pipeline_table
        if defined?(GoodPipeline::PipelineRecord)
          GoodPipeline::PipelineRecord.quoted_table_name
        else
          "good_pipeline_pipelines"
        end
      end

      def step_table
        if defined?(GoodPipeline::StepRecord)
          GoodPipeline::StepRecord.quoted_table_name
        else
          "good_pipeline_steps"
        end
      end

      def quote(value) = connection.quote(value)

      def connection
        @connection ||= if defined?(GoodPipeline::PipelineRecord)
                          GoodPipeline::PipelineRecord.connection
                        else
                          ActiveRecord::Base.connection
                        end
      end

      def default_cache
        Rails.cache if defined?(Rails) && Rails.respond_to?(:cache)
      end
    end
  end
end
