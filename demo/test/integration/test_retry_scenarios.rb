# frozen_string_literal: true

require "test_helper"

class TestRetryScenarios < ActiveSupport::TestCase
  def test_retry_then_succeed_keeps_enqueued_during_retries
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", job_class: "RetryableJob")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])

    tracker_key = SecureRandom.hex(8)
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql(
        ["INSERT INTO attempt_trackers (key, count) VALUES (?, 0)", tracker_key]
      )
    )
    step_a.update_column(:params, { "tracker_key" => tracker_key })

    GoodPipeline::Coordinator.try_enqueue_step(step_a.id)

    saw_failed = false
    wait_until(timeout: 15) do
      perform_enqueued_jobs_inline
      step_a.reload
      saw_failed = true if step_a.coordination_status == "failed"
      step_a.coordination_status == "succeeded"
    end

    refute saw_failed, "coordination_status should never have been 'failed' during retries"
    assert_equal "succeeded", step_a.reload.coordination_status

    perform_enqueued_jobs_inline
    wait_until(timeout: 5) do
      perform_enqueued_jobs_inline
      step_b.reload
      step_b.coordination_status != "pending"
    end

    refute_equal "pending", step_b.reload.coordination_status
  end

  def test_retry_then_exhaust_transitions_to_failed
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a", job_class: "AlwaysFailingJob")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    wait_until(timeout: 15) do
      begin
        perform_enqueued_jobs_inline
      rescue AlwaysFailingJob::AlwaysFailingError
        # Expected — GoodJob re-raises after exhausting retries in inline/external mode
      end
      step.reload
      step.coordination_status == "failed"
    end

    step.reload

    assert_equal "failed", step.coordination_status
    assert_not_nil step.error_class
    assert_not_nil step.error_message
  end

  def test_discard_on_immediate_failure_halts_pipeline
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", job_class: "FailingJob")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])

    GoodPipeline::Coordinator.try_enqueue_step(step_a.id)

    wait_until(timeout: 10) do
      perform_enqueued_jobs_inline
      pipeline.reload
      pipeline.terminal?
    end

    step_a.reload

    assert_equal "failed", step_a.coordination_status
    assert_equal "FailingJob::FailingError", step_a.error_class

    assert_equal "skipped", step_b.reload.coordination_status
    assert_predicate pipeline.reload, :halt_triggered?
    assert_equal "halted", pipeline.status
  end
end
