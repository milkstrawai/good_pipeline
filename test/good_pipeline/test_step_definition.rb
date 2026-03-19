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
      on_failure: :ignore,
      queue: "media",
      priority: 10
    )

    assert_equal :transcode, step.key
    assert_equal DummyJob, step.job_class
    assert_equal({ video_id: 1 }, step.params)
    assert_equal [:download], step.dependencies
    assert_equal :ignore, step.on_failure
    assert_equal "media", step.queue
    assert_equal 10, step.priority
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

  def test_defaults_on_failure_to_nil
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_nil step.on_failure
  end

  def test_defaults_queue_to_nil
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_nil step.queue
  end

  def test_defaults_priority_to_nil
    step = GoodPipeline::StepDefinition.new(key: :a, job_class: DummyJob)

    assert_nil step.priority
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
end
