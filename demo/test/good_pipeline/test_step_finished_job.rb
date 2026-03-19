# frozen_string_literal: true

require "test_helper"

class TestStepFinishedJob < ActiveSupport::TestCase
  def test_delegates_to_coordinator_with_correct_args
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    GoodPipeline::Coordinator.complete_step(step.reload, succeeded: true)

    assert_equal "succeeded", step.reload.coordination_status
  end

  def test_passes_succeeded_false_on_batch_failure
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = create_step(pipeline, key: "a")
    step.update_columns(coordination_status: "enqueued")

    GoodPipeline::Coordinator.complete_step(step.reload, succeeded: false)

    assert_equal "failed", step.reload.coordination_status
  end
end
