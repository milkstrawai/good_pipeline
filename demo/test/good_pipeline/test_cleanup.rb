# frozen_string_literal: true

require_relative "../test_helper"

class TestCleanup < ActiveSupport::TestCase
  setup do
    @now = Time.current

    # Old terminal pipeline (should be cleaned up)
    @old_pipeline = GoodPipeline::PipelineRecord.create!(
      type: "TestPipeline", status: "succeeded", on_failure_strategy: "halt"
    )
    @old_pipeline.update_columns(updated_at: @now - 30.days)

    @old_step = GoodPipeline::StepRecord.create!(
      pipeline: @old_pipeline, key: "step_a", job_class: "DownloadJob", coordination_status: "succeeded"
    )
    @old_dependency = GoodPipeline::DependencyRecord.create!(
      pipeline: @old_pipeline, step: @old_step, depends_on_step: @old_step
    )

    # Old running pipeline (should NOT be cleaned up)
    @running_pipeline = GoodPipeline::PipelineRecord.create!(
      type: "TestPipeline", status: "running", on_failure_strategy: "halt"
    )
    @running_pipeline.update_columns(updated_at: @now - 30.days)
    GoodPipeline::StepRecord.create!(
      pipeline: @running_pipeline, key: "step_a", job_class: "DownloadJob", coordination_status: "enqueued"
    )

    # Recent terminal pipeline (should NOT be cleaned up)
    @recent_pipeline = GoodPipeline::PipelineRecord.create!(
      type: "TestPipeline", status: "failed", on_failure_strategy: "halt"
    )
    GoodPipeline::StepRecord.create!(
      pipeline: @recent_pipeline, key: "step_a", job_class: "DownloadJob", coordination_status: "failed"
    )
  end

  test "cleans old terminal pipelines" do
    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 14.days)

    assert_nil GoodPipeline::PipelineRecord.find_by(id: @old_pipeline.id)
  end

  test "cleans associated steps and dependencies" do
    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 14.days)

    assert_nil GoodPipeline::StepRecord.find_by(id: @old_step.id)
    assert_nil GoodPipeline::DependencyRecord.find_by(id: @old_dependency.id)
  end

  test "preserves running pipelines" do
    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 14.days)

    assert_not_nil GoodPipeline::PipelineRecord.find_by(id: @running_pipeline.id)
  end

  test "preserves recent terminal pipelines" do
    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 14.days)

    assert_not_nil GoodPipeline::PipelineRecord.find_by(id: @recent_pipeline.id)
  end

  test "cleans chain records" do
    downstream = GoodPipeline::PipelineRecord.create!(
      type: "TestPipeline", status: "succeeded", on_failure_strategy: "halt"
    )
    downstream.update_columns(updated_at: @now - 30.days)

    chain = GoodPipeline::ChainRecord.create!(
      upstream_pipeline: @old_pipeline, downstream_pipeline: downstream
    )

    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 14.days)

    assert_nil GoodPipeline::ChainRecord.find_by(id: chain.id)
  end

  test "noop when nothing to clean" do
    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 365.days)

    assert_equal 3, GoodPipeline::PipelineRecord.count
  end

  test "triggers cleanup when GoodJob cleans preserved jobs" do
    GoodJob.cleanup_preserved_jobs(older_than: 14.days)

    assert_nil GoodPipeline::PipelineRecord.find_by(id: @old_pipeline.id)
    assert_not_nil GoodPipeline::PipelineRecord.find_by(id: @running_pipeline.id)
    assert_not_nil GoodPipeline::PipelineRecord.find_by(id: @recent_pipeline.id)
  end
end
