# frozen_string_literal: true

require "test_helper"

class TestStepFinishedIdempotency < ActiveSupport::TestCase
  def test_complete_step_on_already_succeeded_step_is_noop
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "succeeded", finished_at: Time.current)

    GoodPipeline::Coordinator.complete_step(step.reload, succeeded: true)

    assert_equal "succeeded", step.reload.coordination_status
  end

  def test_complete_step_on_already_failed_step_is_noop
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "failed", finished_at: Time.current)

    GoodPipeline::Coordinator.complete_step(step.reload, succeeded: false)

    assert_equal "failed", step.reload.coordination_status
  end

  def test_complete_step_on_already_skipped_step_is_noop
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    step.update_columns(coordination_status: "skipped")

    GoodPipeline::Coordinator.complete_step(step.reload, succeeded: true)

    assert_equal "skipped", step.reload.coordination_status
  end
end
