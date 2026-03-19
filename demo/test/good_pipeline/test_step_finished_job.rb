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
    batch.enqueue { }

    GoodPipeline::StepFinishedJob.new.perform(batch, {})

    assert_equal "succeeded", step.reload.coordination_status
  end

  def test_completes_step_as_failed_when_batch_discarded
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    batch = GoodJob::Batch.new
    batch.properties = { step_id: step.id }
    batch.enqueue { }
    GoodJob::BatchRecord.where(id: batch.id).update_all(discarded_at: Time.current)
    batch = GoodJob::Batch.find(batch.id)

    GoodPipeline::StepFinishedJob.new.perform(batch, {})

    assert_equal "failed", step.reload.coordination_status
  end
end
