#!/usr/bin/env ruby
# frozen_string_literal: true

# In-memory benchmarks for GoodPipeline (no database required).
#
# Usage:
#   bundle exec ruby bench/memory_bench.rb          # human-readable output
#   bundle exec ruby bench/memory_bench.rb --json   # JSON output

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "good_pipeline/constants"
require "good_pipeline/errors"
require "good_pipeline/step_definition"
require "good_pipeline/branch_builder"
require "good_pipeline/cycle_detector"
require "good_pipeline/graph_validator"
require "good_pipeline/pipeline"

require "benchmark/ips"
require_relative "support/topology_builder"
require_relative "support/output_formatter"

SIZES = [10, 50, 100, 200].freeze
TOPOLOGIES = %i[linear diamond].freeze
DEPENDENCY_COUNTS = [0, 5, 10, 20].freeze

json_mode = OutputFormatter.json_mode?
results = {}

# --- 1. Pipeline DSL Construction ---

section = "pipeline_construction"
results[section] = {}

OutputFormatter.print_section_header("Pipeline DSL Construction") unless json_mode

TOPOLOGIES.each do |topology|
  report = Benchmark.ips(time: 1.5, warmup: 0.5, quiet: json_mode) do |benchmark|
    SIZES.each do |size|
      pipeline_class = TopologyBuilder.pipeline_class_for(topology, size)
      benchmark.report("#{size} steps (#{topology})") { pipeline_class.build }
    end
  end

  next unless json_mode

  report.entries.each do |entry|
    results[section][entry.label] = { iterations_per_second: entry.ips.round(1) }
  end
end

# --- 2. Graph Validation ---

section = "graph_validation"
results[section] = {}

OutputFormatter.print_section_header("Graph Validation") unless json_mode

TOPOLOGIES.each do |topology|
  report = Benchmark.ips(time: 1.5, warmup: 0.5, quiet: json_mode) do |benchmark|
    SIZES.each do |size|
      step_definitions = TopologyBuilder.step_definitions_for(topology, size)
      benchmark.report("#{size} steps (#{topology})") do
        GoodPipeline::GraphValidator.validate!(step_definitions)
      end
    end
  end

  next unless json_mode

  report.entries.each do |entry|
    results[section][entry.label] = { iterations_per_second: entry.ips.round(1) }
  end
end

# --- 3. Cycle Detection ---

section = "cycle_detection"
results[section] = {}

OutputFormatter.print_section_header("Cycle Detection") unless json_mode

TOPOLOGIES.each do |topology|
  report = Benchmark.ips(time: 1.5, warmup: 0.5, quiet: json_mode) do |benchmark|
    SIZES.each do |size|
      step_definitions = TopologyBuilder.step_definitions_for(topology, size)
      steps_by_key = step_definitions.to_h { |step| [step.key, step] }
      forward_edges = Hash.new { |hash, key| hash[key] = [] }
      steps_by_key.each_value do |step|
        step.dependencies.each { |dependency_key| forward_edges[dependency_key] << step.key }
      end

      benchmark.report("#{size} steps (#{topology})") do
        GoodPipeline::CycleDetector.check!(steps_by_key, forward_edges)
      end
    end
  end

  next unless json_mode

  report.entries.each do |entry|
    results[section][entry.label] = { iterations_per_second: entry.ips.round(1) }
  end
end

# --- 4. StepDefinition Creation ---

section = "step_definition_creation"
results[section] = {}

OutputFormatter.print_section_header("StepDefinition Creation") unless json_mode

report = Benchmark.ips(time: 1.5, warmup: 0.5, quiet: json_mode) do |benchmark|
  DEPENDENCY_COUNTS.each do |dependency_count|
    dependency_keys = (1..dependency_count).map { |index| :"dep_#{index}" }
    benchmark.report("#{dependency_count} dependencies") do
      GoodPipeline::StepDefinition.new(
        key: :bench_step,
        job_class: "BenchmarkJob",
        dependencies: dependency_keys
      )
    end
  end
end

if json_mode
  report.entries.each do |entry|
    results[section][entry.label] = { iterations_per_second: entry.ips.round(1) }
  end
end

# --- Output ---

OutputFormatter.print_memory_results(results) if json_mode
