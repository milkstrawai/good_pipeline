# frozen_string_literal: true

require "test_helper"

class TestEnqueueAtomicity < ActiveSupport::TestCase
  def test_rollback_cancels_step_transition_and_job_record
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")

    GoodPipeline::StepRecord.transaction do
      GoodPipeline::Coordinator.try_enqueue_step(step.id)
      raise ActiveRecord::Rollback
    end

    step.reload

    assert_equal "pending", step.coordination_status
    assert_nil step.good_job_id
    assert_nil step.good_job_batch_id
    assert_equal 0, GoodJob::Job.count
  end

  def test_step_can_be_re_enqueued_after_rollback
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")

    GoodPipeline::StepRecord.transaction do
      GoodPipeline::Coordinator.try_enqueue_step(step.id)
      raise ActiveRecord::Rollback
    end

    assert_equal "pending", step.reload.coordination_status

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    refute_equal "pending", step.coordination_status
    assert_not_nil step.good_job_id
    assert_not_nil step.good_job_batch_id
    assert GoodJob::Job.exists?(id: step.good_job_id)
  end

  def test_good_job_id_and_record_exist_together
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    assert_not_nil step.good_job_id, "good_job_id should be set after enqueue"
    assert GoodJob::Job.exists?(id: step.good_job_id),
           "GoodJob::Job record should exist for the good_job_id"
  end
end
