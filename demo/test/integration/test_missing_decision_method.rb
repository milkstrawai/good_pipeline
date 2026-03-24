# frozen_string_literal: true

require "test_helper"

class MissingDecisionPipeline < GoodPipeline::Pipeline
  def configure(**)
    run :start, DownloadJob

    branch :decision, after: :start, by: :nonexistent_method do
      on(:yes) { run :do_work, TranscodeJob }
      on(:no) { run :skip_work, CleanupJob }
    end

    run :finish, PublishJob, after: :decision
  end
end

class TestMissingDecisionMethod < ActiveSupport::TestCase
  def test_missing_decision_method_fails_branch_step
    chain = MissingDecisionPipeline.run
    perform_enqueued_jobs_inline

    pipeline = chain.reload
    steps = pipeline.steps.index_by(&:key)

    assert_predicate pipeline, :terminal?
    assert_equal "halted", pipeline.status

    branch_step = steps["decision"]
    assert_equal "failed", branch_step.coordination_status
    assert_equal "GoodPipeline::ConfigurationError", branch_step.error_class
    assert_includes branch_step.error_message, "nonexistent_method"
  end
end
