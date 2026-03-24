# frozen_string_literal: true

require "test_helper"

class SequentialBranchPipeline < GoodPipeline::Pipeline
  def configure(first_choice:, second_choice:, **)
    run :ingest, DownloadJob

    branch :classify, after: :ingest, by: :content_type do
      on(:text) { run :process_text, TranscodeJob }
      on(:image) { run :process_image, ThumbnailJob }
    end

    branch :priority, after: :classify, by: :review_priority do
      on(:high) { run :fast_review, PublishJob }
      on(:low) { run :standard_review, CleanupJob }
    end

    run :finish, DownloadJob, after: :priority
  end

  private

  def content_type = params[:first_choice].to_sym
  def review_priority = params[:second_choice].to_sym
end

class SequentialBranchWithEmptyArmPipeline < GoodPipeline::Pipeline
  def configure(first_choice:, second_choice:, **)
    run :ingest, DownloadJob

    branch :classify, after: :ingest, by: :content_type do
      on(:text) { run :process_text, TranscodeJob }
      on :skip
    end

    branch :priority, after: :classify, by: :review_priority do
      on(:high) { run :fast_review, PublishJob }
      on(:low) { run :standard_review, CleanupJob }
    end

    run :finish, DownloadJob, after: :priority
  end

  private

  def content_type = params[:first_choice].to_sym
  def review_priority = params[:second_choice].to_sym
end

class TestSequentialBranches < ActiveSupport::TestCase
  def test_second_branch_waits_for_first_branch_arm_to_complete
    chain = SequentialBranchPipeline.run(first_choice: "text", second_choice: "high")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", pipeline.status
    assert_equal "succeeded", steps["ingest"].coordination_status
    assert_equal "succeeded", steps["classify"].coordination_status
    assert_equal "succeeded", steps["process_text"].coordination_status
    assert_equal "skipped_by_branch", steps["process_image"].coordination_status
    assert_equal "succeeded", steps["priority"].coordination_status
    assert_equal "succeeded", steps["fast_review"].coordination_status
    assert_equal "skipped_by_branch", steps["standard_review"].coordination_status
    assert_equal "succeeded", steps["finish"].coordination_status
  end

  def test_second_branch_with_image_and_low_priority
    chain = SequentialBranchPipeline.run(first_choice: "image", second_choice: "low")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", pipeline.status
    assert_equal "succeeded", steps["process_image"].coordination_status
    assert_equal "skipped_by_branch", steps["process_text"].coordination_status
    assert_equal "succeeded", steps["standard_review"].coordination_status
    assert_equal "skipped_by_branch", steps["fast_review"].coordination_status
    assert_equal "succeeded", steps["finish"].coordination_status
  end

  def test_second_branch_depends_on_first_branch_exit_steps_not_sentinel
    instance = SequentialBranchPipeline.build(first_choice: "text", second_choice: "high")

    priority_step = instance.steps_by_key[:priority]

    assert_includes priority_step.dependencies, :process_text,
                    "Second branch should depend on first branch's :text exit step"
    assert_includes priority_step.dependencies, :process_image,
                    "Second branch should depend on first branch's :image exit step"
    refute_includes priority_step.dependencies, :classify,
                    "Second branch should NOT depend on first branch's sentinel step"
  end

  def test_empty_arm_chosen_proceeds_to_second_branch
    chain = SequentialBranchWithEmptyArmPipeline.run(first_choice: "skip", second_choice: "high")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", pipeline.status
    assert_equal "skipped_by_branch", steps["process_text"].coordination_status
    assert_equal "succeeded", steps["priority"].coordination_status
    assert_equal "succeeded", steps["fast_review"].coordination_status
    assert_equal "succeeded", steps["finish"].coordination_status
  end

  def test_non_empty_arm_chosen_proceeds_to_second_branch
    chain = SequentialBranchWithEmptyArmPipeline.run(first_choice: "text", second_choice: "low")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", pipeline.status
    assert_equal "succeeded", steps["process_text"].coordination_status
    assert_equal "succeeded", steps["standard_review"].coordination_status
    assert_equal "succeeded", steps["finish"].coordination_status
  end
end
