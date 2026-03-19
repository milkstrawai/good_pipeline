# frozen_string_literal: true

require "active_record_test_helper"

class TestStepFinishedJob < Minitest::Test
  include ActiveRecordTestCase

  def test_delegates_to_coordinator_with_correct_args
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    batch = MockBatch.new
    batch.properties = { step_id: step.id }
    batch._set_succeeded(true)

    GoodPipeline::Coordinator.complete_step(step.reload, succeeded: true)

    assert_equal "succeeded", step.reload.coordination_status
  end

  def test_passes_succeeded_false_on_batch_failure
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    result = GoodPipeline::FailureMetadata::Result.new(error_class: nil, error_message: nil, attempts: 1)
    GoodPipeline::FailureMetadata.stub(:extract, result) do
      GoodPipeline::Coordinator.complete_step(step.reload, succeeded: false)
    end

    assert_equal "failed", step.reload.coordination_status
  end
end
