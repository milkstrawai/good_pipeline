# frozen_string_literal: true

require "test_helper"

class TestStepFinishedJob < ActiveSupport::TestCase
  def test_completes_step_as_succeeded_via_batch
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    batch = GoodJob::Batch.new
    batch.properties = { step_id: step.id }
    batch.enqueue {}
    step.update_columns(good_job_batch_id: batch.id)

    GoodPipeline::StepFinishedJob.new.perform(batch, {})

    assert_equal "succeeded", step.reload.coordination_status
  end

  def test_ignores_a_callback_from_a_batch_the_step_no_longer_belongs_to
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")

    stale_batch = GoodJob::Batch.new
    stale_batch.properties = { step_id: step.id }
    stale_batch.enqueue {}
    step.update_columns(coordination_status: "enqueued", good_job_batch_id: SecureRandom.uuid)

    GoodPipeline::StepFinishedJob.new.perform(stale_batch, {})

    assert_equal "enqueued", step.reload.coordination_status
    assert_equal "running", pipeline.reload.status
  end

  def test_ignores_a_duplicate_callback_after_the_claim_is_consumed
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")

    batch = GoodJob::Batch.new
    batch.properties = { step_id: step.id }
    batch.enqueue {}
    step.update_columns(coordination_status: "enqueued", good_job_batch_id: batch.id)

    GoodPipeline::StepFinishedJob.new.perform(batch, {})
    first_updated_at = step.reload.updated_at

    GoodPipeline::StepFinishedJob.new.perform(batch, {})

    assert_equal "succeeded", step.reload.coordination_status
    assert_equal first_updated_at, step.updated_at
  end

  # Crash-window recovery: the outcome committed but the process died before
  # the settlement recompute. GoodJob redelivers the callback, whose claim
  # finds nothing (the step is already terminal) — the redelivery must still
  # recompute, or the pipeline stays `running` forever.
  def test_unclaimed_redelivery_still_settles_the_pipeline
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")

    batch = GoodJob::Batch.new
    batch.properties = { step_id: step.id }
    batch.enqueue {}
    step.update_columns(coordination_status: "succeeded", good_job_batch_id: batch.id)

    GoodPipeline::StepFinishedJob.new.perform(batch, {})

    assert_equal "succeeded", pipeline.reload.status
  end

  def test_completes_step_as_failed_when_batch_discarded
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    batch = GoodJob::Batch.new
    batch.properties = { step_id: step.id }
    batch.enqueue {}
    step.update_columns(good_job_batch_id: batch.id)
    GoodJob::BatchRecord.where(id: batch.id).update_all(discarded_at: Time.current)
    batch = GoodJob::Batch.find(batch.id)

    GoodPipeline::StepFinishedJob.new.perform(batch, {})

    assert_equal "failed", step.reload.coordination_status
  end
end
