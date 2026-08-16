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

  test "preserves terminal upstream and edge while durable propagation is unconsumed" do
    downstream = GoodPipeline::PipelineRecord.create!(
      type: "TestPipeline", status: "pending", on_failure_strategy: "halt"
    )
    chain = GoodPipeline::ChainRecord.create!(
      upstream_pipeline: @old_pipeline, downstream_pipeline: downstream
    )
    GoodPipeline::PipelineRecord.transaction do
      locked = GoodPipeline::PipelineRecord.lock("FOR UPDATE").find(@old_pipeline.id)
      GoodPipeline::ChainCoordinator.reserve_terminal_state!(locked)
    end

    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 14.days)

    assert GoodPipeline::PipelineRecord.exists?(@old_pipeline.id)
    assert GoodPipeline::PipelineRecord.exists?(downstream.id)
    assert GoodPipeline::ChainRecord.exists?(chain.id)
    assert GoodJob::Job.where(job_class: "GoodPipeline::ChainPropagationJob", finished_at: nil).any? { |job|
      job.serialized_params.fetch("arguments").first.to_s == chain.id.to_s
    }
  end

  test "terminal upstream becomes eligible after downstream leaves pending" do
    downstream = GoodPipeline::PipelineRecord.create!(
      type: "TestPipeline", status: "running", on_failure_strategy: "halt"
    )
    chain = GoodPipeline::ChainRecord.create!(
      upstream_pipeline: @old_pipeline, downstream_pipeline: downstream
    )

    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 14.days)

    refute GoodPipeline::PipelineRecord.exists?(@old_pipeline.id)
    assert GoodPipeline::PipelineRecord.exists?(downstream.id)
    refute GoodPipeline::ChainRecord.exists?(chain.id)
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

  test "skips a candidate whose row is held by a concurrent claim" do
    locked = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    holder = rails_promise do
      GoodPipeline::PipelineRecord.transaction do
        GoodPipeline::PipelineRecord.lock("FOR UPDATE").find(@old_pipeline.id)
        locked.count_down
        release.wait(10)
      end
    end

    assert locked.wait(10), "holder never acquired the row lock"

    GoodPipeline.cleanup_preserved_pipelines(older_than: @now - 14.days)

    release.count_down
    holder.value!(10)

    assert_not_nil GoodPipeline::PipelineRecord.find_by(id: @old_pipeline.id)
    assert_not_nil GoodPipeline::StepRecord.find_by(id: @old_step.id)
    assert_not_nil GoodPipeline::DependencyRecord.find_by(id: @old_dependency.id)
  end
end
