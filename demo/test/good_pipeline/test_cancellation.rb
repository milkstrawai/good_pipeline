# frozen_string_literal: true

require "test_helper"

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength
class TestCancellation < ActiveSupport::TestCase
  def test_cancel_pending_pipeline_cancels_pending_steps_and_finishes
    pipeline = create_pipeline(on_failure_strategy: "halt")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])

    result = GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)

    assert_equal pipeline.id, result.id
    assert_equal "canceled", result.status
    assert_equal "canceled", pipeline.reload.status
    assert_equal %w[canceled canceled], [step_a.reload.coordination_status, step_b.reload.coordination_status]
    refute_nil pipeline.callbacks_dispatched_at
  end

  def test_cancel_running_pipeline_without_enqueued_work_finishes_immediately
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")

    GoodPipeline::Coordinator.cancel_pipeline(pipeline)

    assert_equal "canceled", pipeline.reload.status
    assert_equal "canceled", step.reload.coordination_status
  end

  def test_cancel_running_pipeline_drains_enqueued_work
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    enqueued_step = build_step(pipeline, key: "enqueued")
    pending_step = build_step(pipeline, key: "pending", dependencies: [enqueued_step])
    enqueued_step.update_columns(coordination_status: "enqueued")

    result = GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)

    assert_equal "canceling", result.status
    assert_equal "canceling", pipeline.reload.status
    assert_equal "enqueued", enqueued_step.reload.coordination_status
    assert_equal "canceled", pending_step.reload.coordination_status
    assert_nil pipeline.callbacks_dispatched_at
  end

  def test_cancel_is_idempotent_while_canceling_and_after_canceled
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    first = GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)
    second = GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)

    assert_equal "canceling", first.status
    assert_equal "canceling", second.status
    assert_nil pipeline.reload.callbacks_dispatched_at

    GoodPipeline::Coordinator.complete_step(step.id, succeeded: true)
    dispatched_at = pipeline.reload.callbacks_dispatched_at
    third = GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)

    assert_equal "canceled", third.status
    assert_equal dispatched_at, pipeline.reload.callbacks_dispatched_at
    assert_equal 1, callback_jobs_for(pipeline).count
  end

  def test_cancel_rejects_unrelated_terminal_status
    %w[succeeded failed halted skipped].each do |status|
      pipeline = create_pipeline(on_failure_strategy: "halt")
      pipeline.update_columns(status: status)

      error = assert_raises(GoodPipeline::CancellationConflict) do
        GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)
      end

      assert_equal pipeline.id, error.pipeline_id
      assert_equal status, error.status
    end
  end

  def test_terminal_transition_and_callback_enqueue_roll_back_together
    pipeline = create_pipeline(on_failure_strategy: "halt")
    build_step(pipeline, key: "a")

    GoodPipeline::PipelineRecord.transaction do
      GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)
      raise ActiveRecord::Rollback
    end

    assert_equal "pending", pipeline.reload.status
    assert_nil pipeline.callbacks_dispatched_at
    assert_empty callback_jobs_for(pipeline)
  end

  def test_single_enqueue_is_guarded_once_canceling
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "canceling")
    step = build_step(pipeline, key: "a")

    result = GoodPipeline::Coordinator.try_enqueue_step(step.id)

    refute result
    assert_equal "pending", step.reload.coordination_status
    assert_nil step.good_job_id
  end

  def test_bulk_enqueue_is_guarded_once_canceling
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "canceling")
    step = build_step(pipeline, key: "a")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    assert_equal "pending", step.reload.coordination_status
    assert_nil step.good_job_id
  end

  def test_successful_completion_during_drain_preserves_outcome_and_finalizes
    pipeline, step = canceling_pipeline_with_enqueued_step

    GoodPipeline::Coordinator.complete_step(step, succeeded: true)

    assert_equal "succeeded", step.reload.coordination_status
    assert_equal "canceled", pipeline.reload.status
  end

  def test_failed_completion_during_drain_preserves_outcome_and_metadata
    pipeline, step = canceling_pipeline_with_enqueued_step
    create_good_job_for_step(step, error: "RuntimeError: drain failed", executions_count: 2)

    GoodPipeline::Coordinator.complete_step(step.id, succeeded: false)

    step.reload

    assert_equal "failed", step.coordination_status
    assert_equal "RuntimeError", step.error_class
    assert_equal "drain failed", step.error_message
    assert_equal 2, step.attempts
    assert_equal "canceled", pipeline.reload.status
    refute_predicate pipeline, :halt_triggered?
  end

  def test_halt_requested_completion_during_drain_preserves_halted_step
    pipeline, step = canceling_pipeline_with_enqueued_step
    step.update_columns(halt_requested: true)

    GoodPipeline::Coordinator.complete_step(step.id, succeeded: true)

    assert_equal "halted", step.reload.coordination_status
    assert_equal "canceled", pipeline.reload.status
  end

  def test_only_last_enqueued_completion_finalizes_cancellation
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b")
    [step_a, step_b].each { |step| step.update_columns(coordination_status: "enqueued") }
    GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)

    GoodPipeline::Coordinator.complete_step(step_a.id, succeeded: true)

    assert_equal "canceling", pipeline.reload.status
    assert_nil pipeline.callbacks_dispatched_at

    GoodPipeline::Coordinator.complete_step(step_b.id, succeeded: false)

    assert_equal "canceled", pipeline.reload.status
    refute_nil pipeline.callbacks_dispatched_at
    assert_equal 1, callback_jobs_for(pipeline).count
  end

  def test_recompute_uses_fresh_activity_and_prioritizes_cancellation
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "canceling")
    step = build_step(pipeline, key: "a")
    pipeline.steps.load
    step.update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline)

    assert_equal "canceled", pipeline.reload.status
  end

  def test_cancel_preserves_real_scheduled_good_job
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(
      pipeline,
      key: "scheduled",
      enqueue_options: { "wait" => 3600, "queue" => "slow" }
    )
    dependent = build_step(pipeline, key: "dependent", dependencies: [step])
    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])
    step.reload
    good_job = GoodJob::Job.find(step.good_job_id)
    job_count = GoodJob::Job.count
    step_job_ids = [step.good_job_id, step.good_job_batch_id]
    job_snapshot = good_job.attributes.slice("id", "batch_id", "scheduled_at", "finished_at", "queue_name", "priority")

    GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)

    assert_equal "canceling", pipeline.reload.status
    assert_equal "enqueued", step.reload.coordination_status
    assert_equal step_job_ids, [step.good_job_id, step.good_job_batch_id]
    assert_equal "canceled", dependent.reload.coordination_status
    assert_equal job_count, GoodJob::Job.count
    assert_equal job_snapshot, good_job.reload.attributes.slice(*job_snapshot.keys)
    assert_operator good_job.scheduled_at, :>, Time.current

    GoodPipeline::Coordinator.complete_step(step.id, succeeded: true)

    assert_equal "succeeded", step.reload.coordination_status
    assert_equal "canceled", pipeline.reload.status
  end

  def test_cancel_and_enqueue_race_has_only_serializable_outcomes
    5.times do |iteration|
      pipeline = create_pipeline(on_failure_strategy: "halt")
      pipeline.update_columns(status: "running")
      step = build_step(pipeline, key: "race_#{iteration}")
      latch = Concurrent::CountDownLatch.new(2)

      cancel = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)
      end
      enqueue = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.try_enqueue_step(step.id)
      end

      cancel.value!
      enqueue.value!

      assert_serialized_cancel_enqueue_outcome(pipeline, step, iteration)
    end
  end

  def test_cancel_and_bulk_enqueue_race_has_only_serializable_outcomes
    5.times do |iteration|
      pipeline = create_pipeline(on_failure_strategy: "halt")
      pipeline.update_columns(status: "running")
      step = build_step(pipeline, key: "bulk_race_#{iteration}")
      latch = Concurrent::CountDownLatch.new(2)

      cancel = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)
      end
      enqueue = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])
      end

      cancel.value!
      enqueue.value!

      assert_serialized_cancel_enqueue_outcome(pipeline, step, iteration)
    end
  end

  private

  def canceling_pipeline_with_enqueued_step
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")
    GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)
    [pipeline, step]
  end

  def create_good_job_for_step(step, error:, executions_count:)
    good_job = GoodJob::Job.create!(
      id: SecureRandom.uuid,
      active_job_id: SecureRandom.uuid,
      job_class: step.job_class,
      error: error,
      executions_count: executions_count,
      finished_at: Time.current
    )
    step.update_column(:good_job_id, good_job.id)
  end

  def callback_jobs_for(pipeline)
    GoodJob::Job.where(job_class: "GoodPipeline::PipelineCallbackJob")
                .where("serialized_params -> 'arguments' ->> 0 = ?", pipeline.id)
  end

  def assert_serialized_cancel_enqueue_outcome(pipeline, step, iteration)
    pipeline.reload
    step.reload

    if pipeline.canceled?
      assert_equal "canceled", step.coordination_status, "iteration #{iteration}"
      assert_nil step.good_job_id, "iteration #{iteration}"
    else
      assert_equal "canceling", pipeline.status, "iteration #{iteration}"
      assert_equal "enqueued", step.coordination_status, "iteration #{iteration}"
      refute_nil step.good_job_id, "iteration #{iteration}"
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength
