# frozen_string_literal: true

require "test_helper"
require "json"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require "active_support/core_ext/string/inflections"
require "active_support/isolated_execution_state"
require_relative "../../app/helpers/good_pipeline/mermaid_diagram_builder"
require_relative "../../app/helpers/good_pipeline/pipelines_helper"

class TestPipelinesHelper < Minitest::Test
  include GoodPipeline::PipelinesHelper

  # Stub tag helper for tests
  def tag
    @tag ||= TagBuilder.new
  end

  class TagBuilder
    def span(content, **attributes)
      class_attr = attributes[:class]
      "<span class=\"#{class_attr}\">#{content}</span>"
    end

    def time(content, **attributes)
      datetime = attributes[:datetime]
      title = attributes[:title]
      "<time datetime=\"#{datetime}\" title=\"#{title}\">#{content}</time>"
    end
  end

  FakePipeline = Struct.new(:terminal, :updated_at, :created_at, :steps, :dependencies, :branches) do
    def terminal? = terminal

    def initialize(terminal: false, updated_at: nil, created_at: nil, steps: [], dependencies: [], branches: [])
      super(terminal, updated_at, created_at, steps, dependencies, branches)
    end
  end

  FakeStep = Struct.new(
    :key, :coordination_status, :good_job_id, :job_class, :branch_arm, :branch_key, :id, :empty_arms
  ) do
    def branch_step? = job_class == GoodPipeline::BRANCH_JOB_CLASS
    def branch_arm_step? = branch_arm.present?
  end
  FakeDependency = Struct.new(:depends_on_step, :step, :step_id)

  # --- humanized_type ---

  def test_humanized_type_with_simple_name
    assert_equal "Video Processing Pipeline", humanized_type("VideoProcessingPipeline")
  end

  # --- status_badge ---

  def test_status_badge_for_known_status
    result = status_badge("succeeded")

    assert_includes result, "\u2713 Succeeded"
    assert_includes result, "badge-succeeded"
  end

  def test_status_badge_for_unknown_status_falls_back_to_raw_status
    result = status_badge("custom")

    assert_includes result, "custom"
    assert_includes result, "badge-custom"
  end

  def test_status_badge_converts_symbol_to_string
    result = status_badge(:pending)

    assert_includes result, "\u25CB Pending"
  end

  # --- relative_time ---

  def test_relative_time_nil_returns_empty
    assert_equal "", relative_time(nil)
  end

  def test_relative_time_seconds_ago
    assert_equal "30s ago", relative_time(Time.current - 30)
  end

  def test_relative_time_minutes_ago
    assert_equal "5m ago", relative_time(Time.current - 300)
  end

  def test_relative_time_hours_ago
    assert_equal "2h ago", relative_time(Time.current - 7200)
  end

  def test_relative_time_days_ago
    assert_equal "3d ago", relative_time(Time.current - 259_200)
  end

  # --- pipeline_duration ---

  def test_pipeline_duration_returns_nil_for_non_terminal
    pipeline = FakePipeline.new(terminal: false)

    assert_nil pipeline_duration(pipeline)
  end

  def test_pipeline_duration_less_than_one_second
    now = Time.current
    pipeline = FakePipeline.new(terminal: true, updated_at: now, created_at: now - 0.5)

    assert_equal "< 1s", pipeline_duration(pipeline)
  end

  def test_pipeline_duration_seconds_only
    now = Time.current
    pipeline = FakePipeline.new(terminal: true, updated_at: now, created_at: now - 45)

    assert_equal "45s", pipeline_duration(pipeline)
  end

  def test_pipeline_duration_minutes_and_seconds
    now = Time.current
    pipeline = FakePipeline.new(terminal: true, updated_at: now, created_at: now - 125)

    assert_equal "2m 5s", pipeline_duration(pipeline)
  end

  def test_pipeline_duration_hours_minutes_seconds
    now = Time.current
    pipeline = FakePipeline.new(terminal: true, updated_at: now, created_at: now - 3725)

    assert_equal "1h 2m 5s", pipeline_duration(pipeline)
  end

  # --- truncated_params ---

  def test_truncated_params_with_nil
    assert_equal "", truncated_params(nil)
  end

  def test_truncated_params_with_empty_hash
    assert_equal "", truncated_params({})
  end

  def test_truncated_params_with_short_params
    result = truncated_params({ "name" => "test" })

    assert_equal '{"name":"test"}', result
  end

  def test_truncated_params_with_long_params
    long_value = "x" * 200
    result = truncated_params({ "key" => long_value })

    assert result.end_with?("...")
    assert_operator result.length, :<=, 101
  end

  # --- relative_time_tag ---

  def test_relative_time_tag_with_nil
    assert_equal "", relative_time_tag(nil)
  end

  def test_relative_time_tag_with_datetime
    datetime = Time.current - 60
    result = relative_time_tag(datetime)

    assert_includes result, "<time"
    assert_includes result, datetime.iso8601
  end

  # --- mermaid_definition_diagram ---

  def test_mermaid_definition_diagram
    step_a = FakeStep.new(key: "download", id: 1)
    step_b = FakeStep.new(key: "process", id: 2)
    dependency = FakeDependency.new(
      depends_on_step: step_a,
      step: step_b,
      step_id: 2
    )

    pipeline = FakePipeline.new(steps: [step_a, step_b], dependencies: [dependency])

    result = mermaid_definition_diagram(pipeline)

    assert_includes result, "graph TD"
    assert_includes result, 'n0("download"):::step'
    assert_includes result, "n0 --> n1"
    refute_includes result, "classDef step"
    assert_includes result, "n2"
    assert_includes result, ":::terminal"
    assert_includes result, "n1 --> n2"
  end

  # --- mermaid_diagram ---

  def test_mermaid_diagram_includes_status_classes
    step = FakeStep.new(key: "download", coordination_status: "succeeded", id: 1)
    pipeline = FakePipeline.new(steps: [step], dependencies: [])

    result = mermaid_diagram(pipeline)

    assert_includes result, "graph TD"
    assert_includes result, 'n0("download"):::succeeded'
    refute_includes result, "classDef succeeded"
  end

  def test_mermaid_uses_generated_ids_and_escapes_untrusted_labels
    step = FakeStep.new(key: %(end_node"; x\ncontrol\u0000), coordination_status: "succeeded", id: 1)
    pipeline = FakePipeline.new(steps: [step], dependencies: [])

    result = mermaid_diagram(pipeline)

    assert_includes result, 'n0("end_node#quot;; xcontrol"):::succeeded'
    refute_includes result, 'end_node"; x'
  end

  def test_mermaid_generated_ids_do_not_collide_with_node_like_step_keys
    first = FakeStep.new(key: "n1", coordination_status: "succeeded", id: "step-a")
    second = FakeStep.new(key: "n0", coordination_status: "succeeded", id: "step-b")
    dependency = FakeDependency.new(depends_on_step: first, step: second, step_id: "step-b")
    builder = GoodPipeline::MermaidDiagramBuilder.new(
      FakePipeline.new(steps: [first, second], dependencies: [dependency])
    )

    assert_equal({ "n1" => "n0", "n0" => "n1" }, builder.node_ids)
    assert_equal "n2", builder.terminal_node_id
    assert_includes builder.status_diagram, 'n0("n1"):::succeeded'
    assert_includes builder.status_diagram, 'n1("n0"):::succeeded'
    assert_includes builder.status_diagram, "n0 --> n1"
  end

  def test_mermaid_branch_arm_labels_are_reduced_to_safe_characters
    branch = FakeStep.new(
      key: "route", coordination_status: "succeeded", job_class: GoodPipeline::BRANCH_JOB_CLASS, id: "branch"
    )
    arm = FakeStep.new(
      key: "deliver", coordination_status: "pending", branch_arm: %(yes|-->"\nnext:/!), id: "arm"
    )
    dependency = FakeDependency.new(depends_on_step: branch, step: arm, step_id: "arm")

    graph = mermaid_diagram(FakePipeline.new(steps: [branch, arm], dependencies: [dependency]))

    assert_includes graph, "n0 -->|yes--quotnext:| n1"
    refute_includes graph, "|-->"
    refute_includes graph, "next:/!"
  end

  def test_mermaid_disables_graphs_above_edge_cap
    first = FakeStep.new(key: "first", id: 1)
    second = FakeStep.new(key: "second", id: 2)
    dependencies = Array.new(1_001) do
      FakeDependency.new(depends_on_step: first, step: second, step_id: 2)
    end
    builder = GoodPipeline::MermaidDiagramBuilder.new(
      FakePipeline.new(steps: [first, second], dependencies: dependencies)
    )

    assert_equal 1_001, builder.edge_count
    assert_predicate builder, :overflow?
    refute_predicate builder, :renderable?
  end

  # --- good_job_step_url ---

  def test_good_job_step_url_with_no_good_job_id
    step = FakeStep.new(good_job_id: nil)

    assert_nil good_job_step_url(step)
  end
end
