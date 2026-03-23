# frozen_string_literal: true

require "test_helper"

class TestStepDefinition < Minitest::Test
  DummyJob = Class.new

  def test_initializes_with_all_fields
    step = GoodPipeline::StepDefinition.new(
      key: :transcode,
      job_class: DummyJob,
      params: { video_id: 1 },
      dependencies: [:download],
      failure_strategy: :ignore,
      enqueue_options: { queue: "media", priority: 10 }
    )

    assert_equal :transcode, step.key
    assert_equal DummyJob, step.job_class
    assert_equal({ video_id: 1 }, step.params)
    assert_equal [:download], step.dependencies
    assert_equal :ignore, step.failure_strategy
    assert_equal({ queue: "media", priority: 10 }, step.enqueue_options)
  end

  def test_defaults_params_to_empty_hash
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_equal({}, step.params)
  end

  def test_defaults_dependencies_to_empty_array
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_equal [], step.dependencies
  end

  def test_normalizes_single_dependency_to_array
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob, dependencies: :download)

    assert_equal [:download], step.dependencies
  end

  def test_defaults_failure_strategy_to_nil
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_nil step.failure_strategy
  end

  def test_defaults_enqueue_options_to_empty_hash
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_equal({}, step.enqueue_options)
  end

  def test_is_frozen_after_initialization
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_predicate step, :frozen?
  end

  def test_params_is_frozen
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob, params: { x: 1 })

    assert_predicate step.params, :frozen?
  end

  def test_dependencies_is_frozen
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob, dependencies: [:b])

    assert_predicate step.dependencies, :frozen?
  end

  def test_enqueue_options_is_frozen
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob, enqueue_options: { queue: "high" })

    assert_predicate step.enqueue_options, :frozen?
  end

  def test_accepts_all_supported_enqueue_options
    step = GoodPipeline::StepDefinition.new(
      key: :a,
      job_class: DummyJob,
      enqueue_options: { queue: "high", priority: 10, wait: 300, good_job_labels: ["urgent"], good_job_notify: false }
    )

    assert_equal({ queue: "high", priority: 10, wait: 300, good_job_labels: ["urgent"], good_job_notify: false },
                 step.enqueue_options)
  end

  def test_rejects_wait_until
    error = assert_raises(GoodPipeline::ConfigurationError) do
      GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob, enqueue_options: { wait_until: Time.now })
    end

    assert_includes error.message, "unsupported enqueue options: wait_until"
  end

  def test_rejects_unknown_enqueue_options
    error = assert_raises(GoodPipeline::ConfigurationError) do
      GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob, enqueue_options: { queu: "high" })
    end

    assert_includes error.message, "unsupported enqueue options: queu"
  end

  def test_defaults_branch_key_to_nil
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_nil step.branch_key
  end

  def test_defaults_branch_arm_to_nil
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_nil step.branch_arm
  end

  def test_initializes_with_branch_metadata
    step = GoodPipeline::StepDefinition.new(
      key: :transcode_hd,
      job_class: DummyJob,
      branch_key: :format_check,
      branch_arm: :hd
    )

    assert_equal :format_check, step.branch_key
    assert_equal :hd, step.branch_arm
  end
end
