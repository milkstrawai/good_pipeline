# frozen_string_literal: true

require "test_helper"

class TestCoordinator < ActiveSupport::TestCase
  # --- Helper to create a GoodJob::Job record for failure metadata ---

  def create_good_job_for_step(step, error: "RuntimeError: something broke", executions_count: 3)
    good_job = GoodJob::Job.create!(
      id: SecureRandom.uuid,
      active_job_id: SecureRandom.uuid,
      job_class: step.job_class,
      error: error,
      executions_count: executions_count,
      finished_at: Time.current
    )
    step.update_column(:good_job_id, good_job.id)
    good_job
  end

  # --- complete_step: idempotency ---

  def test_complete_step_idempotent_on_terminal_step
    pipeline = create_pipeline(on_failure_strategy: "halt")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "succeeded")
    step.reload

    complete_step_for(step, succeeded: true)

    assert_equal "succeeded", step.reload.coordination_status
  end

  # --- complete_step: succeeded ---

  def test_complete_step_succeeded_transitions
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")
    step.reload

    complete_step_for(step, succeeded: true)

    assert_equal "succeeded", step.reload.coordination_status
  end

  # --- complete_step: failed ---

  def test_complete_step_failed_transitions_and_sets_metadata
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")
    create_good_job_for_step(step, error: "RuntimeError: something broke", executions_count: 3)
    step.reload

    complete_step_for(step, succeeded: false)

    step.reload

    assert_equal "failed", step.coordination_status
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

    complete_step_for(step_a, succeeded: false)

    assert_equal "failed", step_a.reload.coordination_status
    assert_equal "skipped", step_b.reload.coordination_status
    assert_equal "skipped", step_c.reload.coordination_status
    assert_predicate pipeline.reload, :halt_triggered?
    assert_equal "halted", pipeline.status
  end

  def test_halt_with_step_ignore_exempts_dependents
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    step_c = build_step(pipeline, key: "c")
    step_a.update_columns(coordination_status: "enqueued")

    complete_step_for(step_a, succeeded: false)

    assert_equal "failed", step_a.reload.coordination_status
    # step_b is a direct dependent of step_a (which has failure_strategy: :ignore) — should NOT be skipped
    refute_equal "skipped", step_b.reload.coordination_status
    # step_c is unrelated — should be skipped under :halt
    assert_equal "skipped", step_c.reload.coordination_status
    assert_predicate pipeline.reload, :halt_triggered?
  end

  def test_halt_with_step_ignore_exempts_transitive_descendants
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    step_c = build_step(pipeline, key: "c", dependencies: [step_b])
    step_d = build_step(pipeline, key: "d")
    step_a.update_columns(coordination_status: "enqueued")

    complete_step_for(step_a, succeeded: false)

    refute_equal "skipped", step_b.reload.coordination_status
    refute_equal "skipped", step_c.reload.coordination_status,
                 "Transitive descendant of :ignore step should NOT be skipped by halt"
    assert_equal "skipped", step_d.reload.coordination_status,
                 "Unrelated step should still be skipped under :halt"
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

    complete_step_for(step_a, succeeded: false)

    assert_equal "failed", step_a.reload.coordination_status
    assert_equal "skipped", step_c.reload.coordination_status
    assert_equal "succeeded", step_b.reload.coordination_status
    refute_predicate pipeline.reload, :halt_triggered?
    assert_equal "failed", pipeline.reload.status
  end

  # --- Ignore strategy ---

  def test_ignore_nothing_skipped
    pipeline = create_pipeline(on_failure_strategy: "ignore")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a")
    build_step(pipeline, key: "b", dependencies: [step_a])
    step_a.update_columns(coordination_status: "enqueued")

    complete_step_for(step_a, succeeded: false)

    assert_equal "failed", step_a.reload.coordination_status
    refute_predicate pipeline.reload, :halt_triggered?
  end

  # --- Single-step pipeline reaches terminal ---

  def test_single_step_pipeline_succeeds
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    complete_step_for(step, succeeded: true)

    assert_equal "succeeded", pipeline.reload.status
  end

  # --- try_enqueue_step ---

  def test_try_enqueue_bails_on_non_pending_step
    pipeline = create_pipeline(on_failure_strategy: "halt")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

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

  # --- recompute_pipeline_status: stale-instance fencing ---

  # A recompute holding a pre-settlement instance and a stale "no active steps"
  # hint must not settle a pipeline that was reset behind its back: the fresh
  # state under the row lock has a pending step, so nothing may be written.
  def test_recompute_with_stale_running_instance_does_not_settle_a_reset_pipeline
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "failed")
    stale = GoodPipeline::PipelineRecord.find(pipeline.id)

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
    assert_equal "failed", pipeline.reload.status

    pipeline.update_columns(status: "running", callbacks_dispatched_at: nil)
    step.update_columns(coordination_status: "pending")

    GoodPipeline::Coordinator.recompute_pipeline_status(stale, has_active_steps: false)

    assert_equal "running", pipeline.reload.status
    assert_nil pipeline.callbacks_dispatched_at
  end

  # The inverse: a stale *terminal* instance must not suppress a settlement that
  # the freshly locked row does warrant. Every authoritative check runs against
  # the locked row, so the caller's in-memory copy never decides the outcome.
  def test_recompute_with_stale_terminal_instance_does_not_suppress_settlement
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "failed")
    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)

    stale_terminal = GoodPipeline::PipelineRecord.find(pipeline.id)
    assert_predicate stale_terminal, :terminal?

    pipeline.update_columns(status: "running", callbacks_dispatched_at: nil)
    step.update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(stale_terminal)

    assert_equal "succeeded", pipeline.reload.status
    assert_not_nil pipeline.callbacks_dispatched_at
  end

  # --- cancel_pipeline ---

  def test_cancel_pipeline_skips_pending_steps_and_halts_when_nothing_in_flight
    pipeline = create_pipeline(status: "running")
    step_a = build_step(pipeline, key: "a")
    step_a.update_columns(coordination_status: "succeeded")
    step_b = build_step(pipeline, key: "b")

    assert GoodPipeline::Coordinator.cancel_pipeline(pipeline)

    assert_equal "skipped", step_b.reload.coordination_status
    assert_equal "succeeded", step_a.reload.coordination_status
    assert_equal "halted", pipeline.reload.status
    assert_predicate pipeline, :canceled?
  end

  def test_cancel_pipeline_leaves_in_flight_steps_running_until_they_report_back
    pipeline = create_pipeline(status: "running")
    in_flight = build_step(pipeline, key: "a")
    in_flight.update_columns(coordination_status: "enqueued")
    pending = build_step(pipeline, key: "b")

    assert GoodPipeline::Coordinator.cancel_pipeline(pipeline)

    assert_equal "enqueued", in_flight.reload.coordination_status
    assert_equal "skipped", pending.reload.coordination_status
    assert_equal "running", pipeline.reload.status
    assert_predicate pipeline, :canceling?

    complete_step_for(in_flight, succeeded: true)

    assert_equal "halted", pipeline.reload.status
  end

  # Without the canceled_at guard in derive_terminal_status this settles on
  # "succeeded", reporting a cancellation as a clean run.
  def test_cancel_pipeline_does_not_settle_on_succeeded_without_failures
    pipeline = create_pipeline(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.cancel_pipeline(pipeline)

    assert_equal "halted", pipeline.reload.status
  end

  def test_cancel_pipeline_is_a_no_op_once_terminal
    pipeline = create_pipeline(status: "succeeded")

    refute GoodPipeline::Coordinator.cancel_pipeline(pipeline)

    assert_equal "succeeded", pipeline.reload.status
    refute_predicate pipeline, :canceled?
  end

  def test_cancel_pipeline_only_claims_the_first_caller
    pipeline = create_pipeline(status: "running")
    build_step(pipeline, key: "a").update_columns(coordination_status: "enqueued")

    assert GoodPipeline::Coordinator.cancel_pipeline(pipeline)
    first_canceled_at = pipeline.reload.canceled_at

    refute GoodPipeline::Coordinator.cancel_pipeline(pipeline.reload)
    assert_equal first_canceled_at, pipeline.reload.canceled_at
  end

  def test_cancel_pipeline_skips_downstream_chained_pipelines
    upstream = create_pipeline(status: "running")
    build_step(upstream, key: "a").update_columns(coordination_status: "succeeded")
    downstream = create_pipeline(status: "pending")
    GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: downstream)

    GoodPipeline::Coordinator.cancel_pipeline(upstream)

    assert_equal "halted", upstream.reload.status
    assert_equal "skipped", downstream.reload.status
  end

  def test_cancel_pipeline_dispatches_callbacks_once
    pipeline = create_pipeline(status: "running", type: "TestPipeline")
    build_step(pipeline, key: "a").update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.cancel_pipeline(pipeline)

    assert_not_nil pipeline.reload.callbacks_dispatched_at
    assert_equal 1, callback_job_count

    # A later settlement attempt — an idempotent recompute, a redelivered
    # callback — must not enqueue a second bundle.
    GoodPipeline::Coordinator.dispatch_callbacks_once(pipeline.reload, :halted)

    assert_equal 1, callback_job_count
  end

  # Cancellation drains failures the same way it drains successes: the outcome
  # is recorded with its metadata path intact, and canceled_at — not the
  # failure — decides the terminal status.
  def test_cancel_pipeline_settles_halted_when_the_drained_step_fails
    pipeline = create_pipeline(status: "running")
    in_flight = build_step(pipeline, key: "a")
    in_flight.update_columns(coordination_status: "enqueued")

    assert GoodPipeline::Coordinator.cancel_pipeline(pipeline)
    complete_step_for(in_flight, succeeded: false)

    assert_equal "failed", in_flight.reload.coordination_status
    assert_equal "halted", pipeline.reload.status
  end

  # --- enqueue guards against canceled and settled pipelines ---
  #
  # Deterministic coverage for the locked re-check inside bulk and branch
  # enqueue: the race window is "steps pre-selected as pending, pipeline
  # canceled or settled before the pipeline lock is taken", manufactured here
  # directly instead of relying on thread timing.

  def test_bulk_enqueue_refuses_a_canceled_pipeline
    pipeline = create_pipeline(status: "running")
    root = build_step(pipeline, key: "a")
    pipeline.update_columns(canceled_at: Time.current)

    GoodPipeline::Coordinator.bulk_enqueue_steps([root.id])

    assert_equal "pending", root.reload.coordination_status
    assert_nil root.good_job_id
    assert_equal 0, GoodJob::Job.count
  end

  def test_bulk_enqueue_refuses_a_settled_pipeline
    pipeline = create_pipeline(status: "halted")
    root = build_step(pipeline, key: "a")

    GoodPipeline::Coordinator.bulk_enqueue_steps([root.id])

    assert_equal "pending", root.reload.coordination_status
    assert_equal 0, GoodJob::Job.count
  end

  def test_branch_root_enqueue_refuses_a_canceled_pipeline
    pipeline = create_pipeline(status: "running")
    branch = build_step(
      pipeline,
      key: "decision",
      job_class: GoodPipeline::BRANCH_JOB_CLASS,
      branch: { "decides" => "choose_arm" }
    )
    pipeline.update_columns(canceled_at: Time.current)

    GoodPipeline::Coordinator.bulk_enqueue_steps([branch.id])

    assert_equal "pending", branch.reload.coordination_status
    assert_equal 0, GoodJob::Job.count
  end

  private

  def callback_job_count
    GoodJob::Job.where(job_class: "GoodPipeline::PipelineCallbackJob").count
  end
end
