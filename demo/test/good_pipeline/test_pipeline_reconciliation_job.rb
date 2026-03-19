# frozen_string_literal: true

require "test_helper"

class TestPipelineReconciliationJob < ActiveSupport::TestCase
  def test_recomputes_pipeline_status_for_succeeded_pipeline
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: "a").update_columns(coordination_status: "succeeded")

    batch = GoodJob::Batch.new
    batch.properties = { pipeline_id: pipeline.id }
    batch.save

    GoodPipeline::PipelineReconciliationJob.new.perform(batch, {})

    assert_equal "succeeded", pipeline.reload.status
  end

  def test_does_not_transition_when_steps_still_pending
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: "a")

    batch = GoodJob::Batch.new
    batch.properties = { pipeline_id: pipeline.id }
    batch.save

    GoodPipeline::PipelineReconciliationJob.new.perform(batch, {})

    assert_equal "running", pipeline.reload.status
  end
end
