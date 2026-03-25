# frozen_string_literal: true

require "benchmark"

module QueryCounter
  # Runs the block and returns { wall_time_ms:, query_count: }.
  def self.measure(&block)
    query_count = 0
    counter = lambda { |_name, _start, _finish, _id, payload|
      query_count += 1 unless payload[:name] == "SCHEMA"
    }

    elapsed = nil
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      elapsed = Benchmark.realtime(&block)
    end

    { wall_time_ms: (elapsed * 1000).round(1), query_count: query_count }
  end

  # Runs the block N times, returns the median result.
  def self.median_of(iterations = 5, &block)
    measurements = Array.new(iterations) { measure(&block) }
    sorted = measurements.sort_by { |measurement| measurement[:wall_time_ms] }
    sorted[iterations / 2]
  end
end
