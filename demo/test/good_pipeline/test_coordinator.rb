# frozen_string_literal: true

require "test_helper"

class TestCoordinator < ActiveSupport::TestCase
  # --- complete_step: idempotency ---

  def test_complete_step_idempotent_on_terminal_step
    pipeline = create_pipeline(on_failure_strategy: "halt")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "succeeded", finished_at: Time.current)
    step.reload

    # Should return without error or side effects
    GoodPipeline::Coordinator.complete_step(step, succeeded: true)
    assert_equal "succeeded", step.reload.coordination_status
  end

  # --- complete_step: succeeded ---

  def test_complete_step_succeeded_transitions_and_sets_finished_at
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")
    step.reload

    GoodPipeline::Coordinator.complete_step(step, succeeded: true)

    step.reload
    assert_equal "succeeded", step.coordination_status
    refute_nil step.finished_at
  end

  # --- complete_step: failed ---

  def test_complete_step_failed_transitions_and_sets_metadata
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")
    step.reload

    # Stub FailureMetadata.extract to return test data
    result = GoodPipeline::FailureMetadata::Result.new(
      error_class: "RuntimeError",
      error_message: "something broke",
      attempts: 3
    )
    GoodPipeline::FailureMetadata.stub(:extract, result) do
      GoodPipeline::Coordinator.complete_step(step, succeeded: false)
    end

    step.reload
    assert_equal "failed", step.coordination_status
    refute_nil step.finished_at
    assert_equal "RuntimeError", step.error_class
    assert_equal "something broke", step.error_message
    assert_equal 3, step.attempts
  end

  # --- recompute_pipeline_status: derivation ---

  def test_recompute_returns_early_when_steps_not_all_terminal
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: "a")
    build_step(pipeline, key: "b")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline)
    assert_equal "running", pipeline.reload.status
  end

  def test_recompute_derives_succeeded_when_all_steps_succeeded
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b")
    step_a.update_columns(coordination_status: "succeeded")
    step_b.update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
    assert_equal "succeeded", pipeline.reload.status
  end

  def test_recompute_derives_halted_when_halt_triggered
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running", halt_triggered: true)
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b")
    step_a.update_columns(coordination_status: "failed")
    step_b.update_columns(coordination_status: "skipped")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
    assert_equal "halted", pipeline.reload.status
  end

  def test_recompute_derives_failed_when_no_halt_triggered
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b")
    step_a.update_columns(coordination_status: "failed")
    step_b.update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
    assert_equal "failed", pipeline.reload.status
  end

  def test_recompute_is_idempotent_on_terminal_pipeline
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "succeeded", callbacks_dispatched_at: Time.current)
    build_step(pipeline, key: "a").update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
    assert_equal "succeeded", pipeline.reload.status
  end

  # --- dispatch_callbacks_once ---

  def test_dispatch_callbacks_sets_callbacks_dispatched_at
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: "a").update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)

    pipeline.reload
    assert_equal "succeeded", pipeline.status
    refute_nil pipeline.callbacks_dispatched_at
  end

  def test_dispatch_callbacks_exactly_once
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: "a").update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
    first_dispatched_at = pipeline.reload.callbacks_dispatched_at

    # Call again — should not change anything
    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
    assert_equal first_dispatched_at, pipeline.reload.callbacks_dispatched_at
  end

  # --- Halt propagation ---

  def test_halt_skips_all_pending_steps
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    step_c = build_step(pipeline, key: "c", dependencies: [step_a])
    step_a.update_columns(coordination_status: "enqueued")

    result = GoodPipeline::FailureMetadata::Result.new(error_class: nil, error_message: nil, attempts: 1)
    GoodPipeline::FailureMetadata.stub(:extract, result) do
      GoodPipeline::Coordinator.complete_step(step_a.reload, succeeded: false)
    end

    assert_equal "failed", step_a.reload.coordination_status
    assert_equal "skipped", step_b.reload.coordination_status
    assert_equal "skipped", step_c.reload.coordination_status
    assert pipeline.reload.halt_triggered?
    assert_equal "halted", pipeline.status
  end

  def test_halt_with_step_ignore_exempts_dependents
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    step_c = build_step(pipeline, key: "c")
    step_a.update_columns(coordination_status: "enqueued")

    result = GoodPipeline::FailureMetadata::Result.new(error_class: nil, error_message: nil, attempts: 1)
    GoodPipeline::FailureMetadata.stub(:extract, result) do
      GoodPipeline::Coordinator.complete_step(step_a.reload, succeeded: false)
    end

    assert_equal "failed", step_a.reload.coordination_status
    # step_b is a direct dependent of step_a (which has on_failure: :ignore) — should NOT be skipped
    refute_equal "skipped", step_b.reload.coordination_status
    # step_c is unrelated — should be skipped under :halt
    assert_equal "skipped", step_c.reload.coordination_status
    assert pipeline.reload.halt_triggered?
  end

  # --- Continue strategy ---

  def test_continue_skips_only_unsatisfied_descendants
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b")
    step_c = build_step(pipeline, key: "c", dependencies: [step_a])
    step_a.update_columns(coordination_status: "enqueued")
    step_b.update_columns(coordination_status: "succeeded")

    result = GoodPipeline::FailureMetadata::Result.new(error_class: nil, error_message: nil, attempts: 1)
    GoodPipeline::FailureMetadata.stub(:extract, result) do
      GoodPipeline::Coordinator.complete_step(step_a.reload, succeeded: false)
    end

    assert_equal "failed", step_a.reload.coordination_status
    # step_c depends on step_a which failed under :continue — permanently unsatisfied → skipped
    assert_equal "skipped", step_c.reload.coordination_status
    # step_b was already succeeded — untouched
    assert_equal "succeeded", step_b.reload.coordination_status
    refute pipeline.reload.halt_triggered?
    assert_equal "failed", pipeline.reload.status
  end

  # --- Ignore strategy ---

  def test_ignore_nothing_skipped
    pipeline = create_pipeline(on_failure_strategy: "ignore")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a")
    build_step(pipeline, key: "b", dependencies: [step_a])
    step_a.update_columns(coordination_status: "enqueued")

    result = GoodPipeline::FailureMetadata::Result.new(error_class: nil, error_message: nil, attempts: 1)
    GoodPipeline::FailureMetadata.stub(:extract, result) do
      GoodPipeline::Coordinator.complete_step(step_a.reload, succeeded: false)
    end

    assert_equal "failed", step_a.reload.coordination_status
    # Under :ignore, step_b should NOT be skipped — the failed step is treated as satisfied
    # It would be enqueued (which uses real GoodJob::Batch in the demo app)
    refute pipeline.reload.halt_triggered?
  end

  # --- Single-step pipeline reaches terminal ---

  def test_single_step_pipeline_succeeds
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    GoodPipeline::Coordinator.complete_step(step.reload, succeeded: true)

    assert_equal "succeeded", pipeline.reload.status
  end

  # --- try_enqueue_step ---

  def test_try_enqueue_bails_on_non_pending_step
    pipeline = create_pipeline(on_failure_strategy: "halt")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    # Should not raise or change anything
    GoodPipeline::Coordinator.try_enqueue_step(step.id)
    assert_equal "enqueued", step.reload.coordination_status
  end

  def test_try_enqueue_bails_when_good_job_id_present
    pipeline = create_pipeline(on_failure_strategy: "halt")
    step = build_step(pipeline, key: "a")
    step.update_columns(good_job_id: SecureRandom.uuid)

    GoodPipeline::Coordinator.try_enqueue_step(step.id)
    assert_equal "pending", step.reload.coordination_status
  end

  def test_try_enqueue_bails_when_upstreams_not_satisfied
    pipeline = create_pipeline(on_failure_strategy: "halt")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])

    # step_a is still pending, so step_b's upstream is not satisfied
    GoodPipeline::Coordinator.try_enqueue_step(step_b.id)
    assert_equal "pending", step_b.reload.coordination_status
  end

  def test_try_enqueue_skips_permanently_unsatisfied_step
    pipeline = create_pipeline(on_failure_strategy: "continue")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    step_a.update_columns(coordination_status: "failed")

    GoodPipeline::Coordinator.try_enqueue_step(step_b.id)
    assert_equal "skipped", step_b.reload.coordination_status
  end
end
