# frozen_string_literal: true

require "test_helper"

class UndeclaredArmPipeline < GoodPipeline::Pipeline
  def configure(choice:, **)
    run :start, DownloadJob, with: { choice: choice }

    branch :decision, after: :start, by: :pick do
      on(:yes) { run :do_work, TranscodeJob }
      on :no
    end

    run :finish, CleanupJob, after: :decision
  end

  private

  def pick
    params[:choice].to_sym
  end
end

class UndeclaredArmContinuePipeline < GoodPipeline::Pipeline
  failure_strategy :continue

  def configure(choice:, **)
    run :start, DownloadJob
    run :independent, DownloadJob

    branch :decision, after: :start, by: :pick do
      on(:yes) { run :do_work, TranscodeJob }
      on :no
    end

    run :finish, CleanupJob, after: :decision
  end

  private

  def pick = params[:choice].to_sym
end

class TestUndeclaredBranchArm < ActiveSupport::TestCase
  def test_undeclared_branch_arm_fails_pipeline_with_error_details
    chain = UndeclaredArmPipeline.run(choice: "maybe")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_predicate pipeline, :terminal?, "Pipeline should reach a terminal state"
    assert_equal "succeeded", steps["start"].coordination_status

    branch_step = steps["decision"]
    assert_equal "failed", branch_step.coordination_status
    assert_equal "GoodPipeline::ConfigurationError", branch_step.error_class
    assert_includes branch_step.error_message, "\"maybe\""
    assert_includes branch_step.error_message, ":yes"
    assert_includes branch_step.error_message, ":no"

    assert_equal "skipped", steps["do_work"].coordination_status
    assert_equal "skipped", steps["finish"].coordination_status
  end

  def test_undeclared_branch_arm_under_halt_reaches_halted
    chain = UndeclaredArmPipeline.run(choice: "maybe")
    perform_enqueued_jobs_inline

    pipeline = chain.reload

    assert_equal "halted", pipeline.status
    assert_predicate pipeline, :halt_triggered?
    assert_not_nil pipeline.callbacks_dispatched_at
  end

  def test_undeclared_branch_arm_under_continue_reaches_failed
    chain = UndeclaredArmContinuePipeline.run(choice: "maybe")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "failed", pipeline.status
    refute_predicate pipeline, :halt_triggered?

    assert_equal "failed", steps["decision"].coordination_status
    assert_equal "succeeded", steps["independent"].coordination_status,
                 "Independent step should still succeed under :continue"
    assert_equal "skipped", steps["finish"].coordination_status
  end

  def test_undeclared_branch_arm_on_root_branch_step
    # Branch as the very first step (root step), undeclared arm
    root_branch_class = Class.new(GoodPipeline::Pipeline) do
      define_method(:configure) do |**_kwargs|
        branch :decision, by: :pick do
          on(:yes) { run :do_work, DownloadJob }
          on :no
        end
        run :finish, CleanupJob, after: :decision
      end
      define_method(:pick) { :maybe }
    end
    Object.const_set(:RootBranchUndeclaredPipeline, root_branch_class) unless defined?(::RootBranchUndeclaredPipeline)

    chain = RootBranchUndeclaredPipeline.run
    perform_enqueued_jobs_inline

    pipeline = chain.reload

    assert_predicate pipeline, :terminal?
    assert_equal "halted", pipeline.status

    branch_step = pipeline.steps.find_by(key: "decision")
    assert_equal "failed", branch_step.coordination_status
    assert_equal "GoodPipeline::ConfigurationError", branch_step.error_class
  end

  def test_declared_arm_still_works
    chain = UndeclaredArmPipeline.run(choice: "yes")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", pipeline.status
    assert_equal "succeeded", steps["do_work"].coordination_status
    assert_equal "succeeded", steps["finish"].coordination_status
  end

  def test_declared_empty_arm_still_works
    chain = UndeclaredArmPipeline.run(choice: "no")
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", pipeline.status
    assert_equal "skipped_by_branch", steps["do_work"].coordination_status
    assert_equal "succeeded", steps["finish"].coordination_status
  end
end
