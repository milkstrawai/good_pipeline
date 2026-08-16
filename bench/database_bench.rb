#!/usr/bin/env ruby
# frozen_string_literal: true

# Database benchmarks for GoodPipeline (PostgreSQL required).
#
# Prerequisites:
#   mise docker:start
#   cd demo && bundle exec rails db:test:prepare && cd ..
#
# Usage:
#   bundle exec ruby bench/database_bench.rb          # human-readable output
#   bundle exec ruby bench/database_bench.rb --json   # JSON output

ENV["RAILS_ENV"] = "test"
require_relative "../demo/config/environment"

require "benchmark"
require_relative "support/topology_builder"
require_relative "support/output_formatter"
require_relative "support/query_counter"

begin
  ActiveRecord::Base.connection.execute("SELECT 1")
rescue StandardError => error
  warn "Database connection failed: #{error.message}"
  warn "Run: mise docker:start && cd demo && bundle exec rails db:test:prepare"
  exit 1
end

class BenchmarkJob < ApplicationJob
  def perform(**); end
end

ActiveJob::Base.logger = Logger.new(nil)
ActiveRecord::Base.logger = nil

SIZES = [10, 50].freeze
TOPOLOGIES = %i[linear fan_out fan_in diamond].freeze
ITERATIONS = 3

json_mode = OutputFormatter.json_mode?
results = {}

def truncate_tables
  ActiveRecord::Base.connection.truncate_tables(
    "good_pipeline_dependencies",
    "good_pipeline_steps",
    "good_pipeline_chains",
    "good_pipeline_pipelines",
    "good_job_batches",
    "good_jobs"
  )
end

def create_pipeline_records(topology, size)
  pipeline_class = TopologyBuilder.pipeline_class_for(topology, size)
  instance = pipeline_class.build
  pipeline_record = GoodPipeline::Runner.call(instance, start: false)
  step_records = pipeline_record.steps.index_by(&:key)
  [pipeline_record, step_records]
end

def topological_order(pipeline_record) # rubocop:disable Metrics/MethodLength
  steps = pipeline_record.steps.includes(:upstream_steps).to_a
  ordered = []
  visited = Set.new

  visit = lambda { |step|
    return if visited.include?(step.id)

    step.upstream_steps.each { |upstream| visit.call(upstream) }
    visited << step.id
    ordered << step
  }

  steps.each { |step| visit.call(step) }
  ordered
end

# complete_step claims by (step_id, batch_id): the outcome applies only while the
# step is still `enqueued` and owned by the batch that reported it.
def complete(step, succeeded:)
  GoodPipeline::Coordinator.complete_step(
    step_id: step.id,
    batch_id: step.good_job_batch_id,
    succeeded: succeeded
  )
end

def prepare_step_for_completion(pipeline_record)
  pipeline_record.transition_to!(:running)
  ordered_steps = topological_order(pipeline_record)
  first_step = ordered_steps.first
  first_step.update_columns(coordination_status: "enqueued")

  batch = GoodJob::Batch.new
  batch.save
  first_step.update_columns(good_job_batch_id: batch.id)

  first_step.reload
end

def run_benchmark(iterations: ITERATIONS)
  measurements = Array.new(iterations) do
    result = yield
    truncate_tables
    result
  end
  sorted = measurements.sort_by { |measurement| measurement[:wall_time_ms] }
  sorted[iterations / 2]
end

# --- 1. Pipeline Creation (Runner) ---

section = "pipeline_creation"
results[section] = {}

OutputFormatter.print_section_header("Pipeline Creation (Runner)") unless json_mode

TOPOLOGIES.each do |topology|
  SIZES.each do |size|
    pipeline_class = TopologyBuilder.pipeline_class_for(topology, size)
    label = "#{size} steps (#{topology})"

    measurement = run_benchmark do
      instance = pipeline_class.build
      QueryCounter.measure { GoodPipeline::Runner.call(instance, start: false) }
    end

    if json_mode
      results[section][label] = measurement
    else
      OutputFormatter.print_database_row(label, measurement[:wall_time_ms], measurement[:query_count])
    end
  end
end

# --- 2. Step Enqueue (Coordinator.try_enqueue_step) ---

section = "step_enqueue"
results[section] = {}

OutputFormatter.print_section_header("Step Enqueue (Coordinator.try_enqueue_step)") unless json_mode

TOPOLOGIES.each do |topology|
  SIZES.each do |size|
    label = "#{size} steps (#{topology})"

    measurement = run_benchmark do
      pipeline_record, step_records = create_pipeline_records(topology, size)
      pipeline_record.transition_to!(:running)
      root_step = step_records.values.first

      QueryCounter.measure { GoodPipeline::Coordinator.try_enqueue_step(root_step.id) }
    end

    if json_mode
      results[section][label] = measurement
    else
      OutputFormatter.print_database_row(label, measurement[:wall_time_ms], measurement[:query_count])
    end
  end
end

# --- 3. Step Completion (Coordinator.complete_step) ---

section = "step_completion"
results[section] = {}

OutputFormatter.print_section_header("Step Completion (Coordinator.complete_step)") unless json_mode

TOPOLOGIES.each do |topology|
  SIZES.each do |size|
    label = "#{size} steps (#{topology})"

    measurement = run_benchmark do
      pipeline_record, _step_records = create_pipeline_records(topology, size)
      first_step = prepare_step_for_completion(pipeline_record)

      QueryCounter.measure { complete(first_step, succeeded: true) }
    end

    if json_mode
      results[section][label] = measurement
    else
      OutputFormatter.print_database_row(label, measurement[:wall_time_ms], measurement[:query_count])
    end
  end
end

# --- 4. Pipeline Status Recomputation ---

section = "status_recomputation"
results[section] = {}

OutputFormatter.print_section_header("Pipeline Status Recomputation") unless json_mode

TOPOLOGIES.each do |topology|
  SIZES.each do |size|
    label = "#{size} steps (#{topology})"

    measurement = run_benchmark do
      pipeline_record, _step_records = create_pipeline_records(topology, size)
      pipeline_record.transition_to!(:running)
      pipeline_record.steps.update_all(coordination_status: "succeeded")

      QueryCounter.measure { GoodPipeline::Coordinator.recompute_pipeline_status(pipeline_record.reload) }
    end

    if json_mode
      results[section][label] = measurement
    else
      OutputFormatter.print_database_row(label, measurement[:wall_time_ms], measurement[:query_count])
    end
  end
end

# --- 5. Halt Propagation ---

section = "halt_propagation"
results[section] = {}

OutputFormatter.print_section_header("Halt Propagation") unless json_mode

%i[linear diamond].each do |topology|
  SIZES.each do |size|
    label = "#{size} steps (#{topology})"

    measurement = run_benchmark do
      pipeline_class = TopologyBuilder.pipeline_class_for(topology, size)
      pipeline_class.failure_strategy(:halt)
      instance = pipeline_class.build
      pipeline_record = GoodPipeline::Runner.call(instance, start: false)
      first_step = prepare_step_for_completion(pipeline_record)

      QueryCounter.measure { complete(first_step, succeeded: false) }
    end

    if json_mode
      results[section][label] = measurement
    else
      OutputFormatter.print_database_row(label, measurement[:wall_time_ms], measurement[:query_count])
    end
  end
end

# --- 6. Full Pipeline Run ---

section = "full_pipeline_run"
results[section] = {}

OutputFormatter.print_section_header("Full Pipeline Run") unless json_mode

TOPOLOGIES.each do |topology|
  SIZES.each do |size|
    label = "#{size} steps (#{topology})"

    measurement = run_benchmark do
      QueryCounter.measure do
        pipeline_class = TopologyBuilder.pipeline_class_for(topology, size)
        instance = pipeline_class.build
        pipeline_record = GoodPipeline::Runner.call(instance, start: true)

        ordered_steps = topological_order(pipeline_record)
        ordered_steps.each do |step|
          step.reload
          next unless step.enqueued?

          complete(step, succeeded: true)
        end
      end
    end

    if json_mode
      results[section][label] = measurement
    else
      OutputFormatter.print_database_row(label, measurement[:wall_time_ms], measurement[:query_count])
    end
  end
end

# --- Output ---

if json_mode
  database_name = ActiveRecord::Base.connection.current_database
  OutputFormatter.print_database_results(results, database_name: database_name)
end
