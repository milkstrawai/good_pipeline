# frozen_string_literal: true

require "json"

module OutputFormatter
  def self.json_mode?
    ARGV.include?("--json")
  end

  def self.base_metadata
    {
      ruby_version: RUBY_VERSION,
      timestamp: Time.now.utc.iso8601
    }
  end

  # --- Memory bench (benchmark-ips) ---

  def self.print_memory_results(results)
    metadata = base_metadata.merge(benchmark: "memory")
    puts JSON.pretty_generate(metadata.merge(results: results))
  end

  def self.print_section_header(title)
    puts
    puts "=== #{title} ==="
  end

  # --- Database bench (wall time + query count) ---

  def self.print_database_results(results, database_name:)
    metadata = base_metadata.merge(benchmark: "database", database: database_name)
    puts JSON.pretty_generate(metadata.merge(results: results))
  end

  def self.print_database_row(label, wall_time_ms, query_count)
    printf "  %-30<label>s %8.1<ms>fms  %4<queries>d queries\n", label: label, ms: wall_time_ms, queries: query_count
  end
end
