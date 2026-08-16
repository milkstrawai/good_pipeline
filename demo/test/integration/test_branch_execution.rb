# frozen_string_literal: true

require "test_helper"

class BranchDecisionFailure < StandardError; end

class RaisingRootBranchPipeline < GoodPipeline::Pipeline
  failure_strategy :halt

  def configure(**)
    branch :decision, by: :raise_decision_error do
      on(:run) { run :work, DownloadJob }
      on(:skip)
    end

    run :finish, CleanupJob, after: :decision
  end

  private

  def raise_decision_error
    raise BranchDecisionFailure, "decision code exploded"
  end
end

class RaisingNonRootBranchPipeline < GoodPipeline::Pipeline
  failure_strategy :continue

  def configure(**)
    run :start, DownloadJob

    branch :decision, after: :start, by: :raise_decision_error do
      on(:run) { run :work, TranscodeJob }
      on(:skip)
    end

    run :finish, CleanupJob, after: :decision
  end

  private

  def raise_decision_error
    raise BranchDecisionFailure, "later decision code exploded"
  end
end

class TestBranchExecution < ActiveSupport::TestCase
  def test_full_branch_pipeline_hd_path
    chain = BranchTestPipeline.run(choice: "hd")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    assert_equal "succeeded", pipeline.status

    steps = pipeline.steps.index_by(&:key)
    assert_equal "succeeded", steps["analyze"].coordination_status
    assert_equal "succeeded", steps["format_check"].coordination_status
    assert_equal "succeeded", steps["transcode_hd"].coordination_status
    assert_equal "succeeded", steps["upscale"].coordination_status
    assert_equal "skipped_by_branch", steps["transcode_sd"].coordination_status
    assert_equal "succeeded", steps["finish"].coordination_status

    branch_step = steps["format_check"]
    assert_equal "hd", branch_step.branch_result
  end

  def test_full_branch_pipeline_sd_path
    chain = BranchTestPipeline.run(choice: "sd")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", pipeline.status
    assert_equal "succeeded", steps["analyze"].coordination_status
    assert_equal "succeeded", steps["format_check"].coordination_status
    assert_equal "skipped_by_branch", steps["transcode_hd"].coordination_status
    assert_equal "skipped_by_branch", steps["upscale"].coordination_status
    assert_equal "succeeded", steps["transcode_sd"].coordination_status
    assert_equal "succeeded", steps["finish"].coordination_status
  end

  def test_branch_skipped_arm_satisfies_downstream
    chain = BranchTestPipeline.run(choice: "hd")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    finish_step = pipeline.steps.find_by(key: "finish")

    assert_equal "succeeded", finish_step.coordination_status
  end

  def test_branch_with_multiple_steps_per_arm
    chain = BranchTestPipeline.run(choice: "hd")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", steps["transcode_hd"].coordination_status
    assert_equal "succeeded", steps["upscale"].coordination_status
  end

  def test_branch_decision_result_cached_on_step
    chain = BranchTestPipeline.run(choice: "sd")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    branch_step = pipeline.steps.find_by(key: "format_check")

    assert_equal "sd", branch_step.branch_result
  end

  def test_branch_step_is_real_step_with_sentinel_job_class
    chain = BranchTestPipeline.run(choice: "hd")

    pipeline = chain.reload
    branch_step = pipeline.steps.find_by(key: "format_check")

    assert_predicate branch_step, :branch_step?
    assert_equal GoodPipeline::BRANCH_JOB_CLASS, branch_step.job_class
    assert_equal "pick_format", branch_step.decides
  end

  def test_arm_steps_have_branch_metadata
    chain = BranchTestPipeline.run(choice: "hd")

    pipeline = chain.reload
    arm_steps = pipeline.steps.select(&:branch_arm_step?)

    assert_equal 3, arm_steps.size
    arm_steps.each { |step| assert_equal "format_check", step.branch_key }

    hd_steps = arm_steps.select { |step| step.branch_arm == "hd" }
    sd_steps = arm_steps.select { |step| step.branch_arm == "sd" }

    assert_equal 2, hd_steps.size
    assert_equal 1, sd_steps.size
  end

  def test_root_branch_exception_is_recorded_with_original_metadata_and_settles
    pipeline = RaisingRootBranchPipeline.run.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "halted", pipeline.status
    assert_predicate pipeline, :halt_triggered?
    assert_equal "failed", steps.fetch("decision").coordination_status
    assert_equal "BranchDecisionFailure", steps.fetch("decision").error_class
    assert_equal "decision code exploded", steps.fetch("decision").error_message
    assert_equal "skipped", steps.fetch("work").coordination_status
    assert_equal "skipped", steps.fetch("finish").coordination_status
  end

  def test_branch_user_exception_wrapper_retains_the_original_cause
    pipeline = GoodPipeline::Runner.call(RaisingRootBranchPipeline.build, start: false)
    branch_step = pipeline.steps.find_by!(key: "decision")

    error = assert_raises(GoodPipeline::DeterministicStepStartError) do
      GoodPipeline::BranchResolver.resolve(branch_step)
    end

    assert_instance_of BranchDecisionFailure, error.original_error
    assert_same error.original_error, error.cause
    assert_equal "decision code exploded", error.original_error.message
    assert_equal "pending", branch_step.reload.coordination_status
  end

  def test_non_root_branch_exception_uses_the_same_coordinated_failure_path
    chain = RaisingNonRootBranchPipeline.run

    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "failed", pipeline.status
    assert_equal "succeeded", steps.fetch("start").coordination_status
    assert_equal "failed", steps.fetch("decision").coordination_status
    assert_equal "BranchDecisionFailure", steps.fetch("decision").error_class
    assert_equal "later decision code exploded", steps.fetch("decision").error_message
    assert_equal "skipped", steps.fetch("work").coordination_status
    assert_equal "skipped", steps.fetch("finish").coordination_status
  end
end
