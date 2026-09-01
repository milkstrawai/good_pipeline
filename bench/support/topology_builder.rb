# frozen_string_literal: true

module TopologyBuilder
  JOB_CLASS = "BenchmarkJob"

  # Returns an Array<StepDefinition> for use in GraphValidator/CycleDetector benchmarks.
  def self.step_definitions_for(topology, size)
    configs = step_configs_for(topology, size)
    configs.map do |config|
      GoodPipeline::StepDefinition.new(
        key: config[:key],
        job_class: JOB_CLASS,
        dependencies: config[:dependencies]
      )
    end
  end

  # Returns a Pipeline subclass for use in DSL construction benchmarks.
  def self.pipeline_class_for(topology, size)
    configs = step_configs_for(topology, size)
    constant_name = pipeline_constant_name(topology, size)
    klass = build_pipeline_class(configs)
    Object.send(:remove_const, constant_name) if Object.const_defined?(constant_name, false)
    Object.const_set(constant_name, klass)
  end

  def self.build_pipeline_class(configs)
    Class.new(GoodPipeline::Pipeline) do
      define_method(:configure) do |**_kwargs|
        configs.each do |config|
          run config[:key], JOB_CLASS, after: config[:dependencies]
        end
      end
    end
  end

  def self.pipeline_constant_name(topology, size)
    topology_name = topology.to_s.split("_").map(&:capitalize).join
    "Bench#{topology_name}#{size}Pipeline"
  end

  # Returns raw step configs as Array<Hash> with :key and :dependencies.
  def self.step_configs_for(topology, size)
    case topology
    when :linear then linear_configs(size)
    when :fan_out then fan_out_configs(size)
    when :fan_in then fan_in_configs(size)
    when :diamond then diamond_configs(size)
    else raise ArgumentError, "unknown topology: #{topology}"
    end
  end

  # step_1 -> step_2 -> ... -> step_N
  def self.linear_configs(size)
    (1..size).map do |index|
      {
        key: :"step_#{index}",
        dependencies: index == 1 ? [] : [:"step_#{index - 1}"]
      }
    end
  end

  # root -> [leaf_1, leaf_2, ..., leaf_N]
  def self.fan_out_configs(size)
    configs = [{ key: :root, dependencies: [] }]
    size.times do |index|
      configs << { key: :"leaf_#{index + 1}", dependencies: [:root] }
    end
    configs
  end

  # [source_1, source_2, ..., source_N] -> collector
  def self.fan_in_configs(size)
    source_keys = (1..size).map { |index| :"source_#{index}" }
    configs = source_keys.map { |key| { key: key, dependencies: [] } }
    configs << { key: :collector, dependencies: source_keys }
    configs
  end

  # root -> [middle_1, ..., middle_N] -> collector
  def self.diamond_configs(width)
    middle_keys = (1..width).map { |index| :"middle_#{index}" }
    configs = [{ key: :root, dependencies: [] }]
    middle_keys.each { |key| configs << { key: key, dependencies: [:root] } }
    configs << { key: :collector, dependencies: middle_keys }
    configs
  end

  private_class_method :build_pipeline_class, :pipeline_constant_name,
                       :linear_configs, :fan_out_configs, :fan_in_configs, :diamond_configs
end
