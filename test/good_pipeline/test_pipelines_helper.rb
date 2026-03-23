# frozen_string_literal: true

require "test_helper"
require "json"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require "active_support/core_ext/string/inflections"
require "active_support/isolated_execution_state"
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

  FakeStep = Struct.new(:key, :coordination_status, :good_job_id, :job_class, :branch_arm, :id, :empty_arms) do
    def branch_step? = job_class == GoodPipeline::Pipeline::BRANCH_JOB_CLASS
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

  def test_relative_time_just_now
    assert_equal "just now", relative_time(Time.current - 30)
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
    assert_includes result, 'download("download"):::step'
    assert_includes result, "download --> process"
    assert_includes result, "classDef step"
    assert_includes result, "end_node"
    assert_includes result, ":::terminal"
    assert_includes result, "process --> end_node"
  end

  # --- mermaid_diagram ---

  def test_mermaid_diagram_includes_status_classes
    step = FakeStep.new(key: "download", coordination_status: "succeeded", id: 1)
    pipeline = FakePipeline.new(steps: [step], dependencies: [])

    result = mermaid_diagram(pipeline)

    assert_includes result, "graph TD"
    assert_includes result, 'download("download"):::succeeded'
    assert_includes result, "classDef succeeded"
  end

  # --- good_job_step_url ---

  def test_good_job_step_url_with_no_good_job_id
    step = FakeStep.new(good_job_id: nil)

    assert_nil good_job_step_url(step)
  end
end
