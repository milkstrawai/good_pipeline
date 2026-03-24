# frozen_string_literal: true

require "test_helper"

class StepIgnoreBranchPipeline < GoodPipeline::Pipeline
  failure_strategy :halt

  def configure(choice:, **)
    run :start, DownloadJob
    run :optional, FailingJob, after: :start, on_failure: :ignore
    run :after_optional, TranscodeJob, after: :optional
    run :after_after_optional, ThumbnailJob, after: :after_optional

    branch :check, after: :after_after_optional, by: :pick do
      on(:yes) { run :do_work, PublishJob }
      on :no
    end

    run :finish, CleanupJob, after: :check
  end

  private

  def pick = params[:choice].to_sym
end

class TestHaltIgnoreChain < ActiveSupport::TestCase
  def test_halt_ignore_with_branch_succeeds
    chain = StepIgnoreBranchPipeline.run(choice: "yes")

    wait_until(timeout: 15) do
      perform_enqueued_jobs_inline
      chain.reload
      chain.terminal?
    end

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_equal "halted", pipeline.status
    assert_equal "succeeded", steps["start"].coordination_status
    assert_equal "failed", steps["optional"].coordination_status
    refute_equal "skipped", steps["after_optional"].coordination_status,
                 "Transitive descendant of :ignore step should NOT be skipped"
    refute_equal "skipped", steps["after_after_optional"].coordination_status,
                 "Deep transitive descendant of :ignore step should NOT be skipped"
  end

  def test_late_then_after_halt_skips_downstream
    chain = StepIgnoreBranchPipeline.run(choice: "yes")

    wait_until(timeout: 15) do
      perform_enqueued_jobs_inline
      chain.reload
      chain.terminal?
    end

    assert_predicate chain.reload, :terminal?

    chain.then(NotificationPipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a

    wait_until(timeout: 10) do
      perform_enqueued_jobs_inline
      all_records.each(&:reload)
      all_records.all?(&:terminal?)
    end

    downstream = all_records.find { |pipeline| pipeline.type == "NotificationPipeline" }

    assert_equal "skipped", downstream.status,
                 "Downstream registered after upstream halted should be skipped"
  end
end
