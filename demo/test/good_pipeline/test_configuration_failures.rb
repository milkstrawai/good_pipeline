# frozen_string_literal: true

require "test_helper"

# Class names stored on pipeline/step rows outlive the code that defined them.
# Every resolution site must normalize NameError into ConfigurationError so the
# step fails visibly and the pipeline settles — instead of the NameError
# escaping StepFinishedJob (no retry policy → discarded → coordination event
# lost → pipeline wedged in `running`).
class TestConfigurationFailures < ActiveSupport::TestCase
  def test_missing_job_class_fails_the_step_instead_of_raising
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a", job_class: "RemovedJob")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    assert_equal "failed", step.coordination_status
    assert_equal "GoodPipeline::ConfigurationError", step.error_class
    assert_match(/RemovedJob/, step.error_message)
    assert_equal "failed", pipeline.reload.status
  end

  def test_missing_pipeline_class_fails_the_step_instead_of_raising
    pipeline = create_pipeline(type: "RemovedPipeline", on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    assert_equal "failed", step.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  def test_missing_pipeline_class_on_a_branch_step_fails_the_step
    pipeline = create_pipeline(type: "RemovedPipeline", on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(
      pipeline,
      key: "decision",
      job_class: GoodPipeline::BRANCH_JOB_CLASS,
      branch: { "decides" => "choose_arm" }
    )

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    assert_equal "failed", step.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  def test_all_roots_failing_configuration_settles_the_pipeline_instead_of_wedging_it
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", job_class: "RemovedJob")
    step_b = build_step(pipeline, key: "b", job_class: "AlsoRemovedJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])

    assert_equal "failed", step_a.reload.coordination_status
    assert_equal "failed", step_b.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  # Under :halt, the first failure's propagation skips the second pending
  # step; the fresh conditional re-claim must then leave it `skipped` rather
  # than stamping `failed` over it through a stale in-memory record.
  def test_bulk_multi_failure_under_halt_leaves_later_steps_skipped
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", job_class: "RemovedJob")
    step_b = build_step(pipeline, key: "b", job_class: "AlsoRemovedJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])

    statuses = [step_a.reload.coordination_status, step_b.reload.coordination_status].sort

    assert_equal %w[failed skipped], statuses
    assert_equal "halted", pipeline.reload.status
  end

  def test_bulk_failure_cascades_skips_to_dependents
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    root = build_step(pipeline, key: "root", job_class: "RemovedJob")
    child = build_step(pipeline, key: "child", dependencies: [root])

    GoodPipeline::Coordinator.bulk_enqueue_steps([root.id])

    assert_equal "failed", root.reload.coordination_status
    assert_equal "skipped", child.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  # A configuration failure reaches a terminal state without a StepFinishedJob
  # callback, so it must decrement its dependents' upstream counts itself.
  # Under :ignore with a fan-in dependent, missing that decrement leaves the
  # dependent waiting on a count that never reaches zero once the other
  # upstream completes — pipeline wedged in `running`.
  def test_ignore_config_failure_does_not_strand_fan_in_dependents
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", job_class: "RemovedJob", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b")
    step_d = build_step(pipeline, key: "d", dependencies: [step_a, step_b])

    GoodPipeline::Coordinator.try_enqueue_step(step_a.id)

    assert_equal "failed", step_a.reload.coordination_status

    step_b.update_columns(coordination_status: "enqueued")
    complete_step_for(step_b, succeeded: true)

    assert_equal "enqueued", step_d.reload.coordination_status,
                 "Fan-in dependent of an :ignore config failure should run once its other upstream succeeds"

    complete_step_for(step_d, succeeded: true)

    assert_equal "failed", pipeline.reload.status
  end

  def test_missing_pipeline_class_does_not_roll_back_settlement
    pipeline = create_pipeline(type: "RemovedPipeline", on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: "a").update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)

    pipeline.reload

    assert_equal "succeeded", pipeline.status
    assert_not_nil pipeline.callbacks_dispatched_at
  end
end
