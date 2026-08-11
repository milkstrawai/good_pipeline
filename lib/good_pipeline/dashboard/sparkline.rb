# frozen_string_literal: true

module GoodPipeline
  module Dashboard
    # A zero-filled, oldest-to-newest series of daily execution counts.
    class Sparkline
      DAYS = 14

      def initialize(pipeline_type: nil, now: Time.current, connection: nil)
        @pipeline_type = pipeline_type.to_s.empty? ? nil : pipeline_type.to_s
        @now = now
        @connection = connection
      end

      def buckets # rubocop:disable Metrics/AbcSize
        @buckets ||= begin
          rows = connection.select_all(<<~SQL).to_a
            SELECT date_trunc('day', created_at) AS day, COUNT(*) AS n
            FROM #{pipeline_table}
            WHERE created_at >= #{quote(first_day.beginning_of_day)}
              AND created_at < #{quote((last_day + 1.day).beginning_of_day)}
              #{type_scope}
            GROUP BY day
            ORDER BY day
          SQL

          counts = rows.to_h do |row|
            day = row["day"] || row[:day]
            count = row["n"] || row[:n]
            [day.to_date, count.to_i]
          end

          (first_day..last_day).map { |day| counts.fetch(day, 0) }.freeze
        end
      end

      # Percent heights are convenient for the server-rendered bar elements.
      # Keeping the denominator at least one makes an all-zero series safe.
      def heights
        values = buckets
        denominator = [values.max.to_i, 1].max
        values.map { |value| (value.to_f / denominator) * 100.0 }
      end

      private

      def first_day = last_day - (DAYS - 1).days
      def last_day = @now.to_date

      def type_scope
        @pipeline_type ? "AND type = #{quote(@pipeline_type)}" : ""
      end

      def pipeline_table
        if defined?(GoodPipeline::PipelineRecord)
          GoodPipeline::PipelineRecord.quoted_table_name
        else
          "good_pipeline_pipelines"
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
    end
  end
end
