# frozen_string_literal: true

require "test_helper"

class TestFailureMetadata < ActiveSupport::TestCase
  def test_extract_returns_empty_result_when_no_good_job_record
    pipeline = create_pipeline
    step = build_step(pipeline, key: "a")

    result = GoodPipeline::FailureMetadata.extract(step)

    assert_nil result.error_class
    assert_nil result.error_message
    assert_equal 0, result.attempts
  end

  def test_extract_parses_error_from_good_job_record
    pipeline = create_pipeline
    step = build_step(pipeline, key: "a")

    good_job = GoodJob::Job.create!(
      id: SecureRandom.uuid,
      active_job_id: SecureRandom.uuid,
      job_class: "DownloadJob",
      error: "RuntimeError: something went wrong",
      executions_count: 3,
      finished_at: Time.current
    )
    step.update_column(:good_job_id, good_job.id)

    result = GoodPipeline::FailureMetadata.extract(step.reload)

    assert_equal "RuntimeError", result.error_class
    assert_equal "something went wrong", result.error_message
    assert_equal 3, result.attempts
  end

  def test_extract_handles_error_message_with_colon
    pipeline = create_pipeline
    step = build_step(pipeline, key: "a")

    good_job = GoodJob::Job.create!(
      id: SecureRandom.uuid,
      active_job_id: SecureRandom.uuid,
      job_class: "DownloadJob",
      error: "Net::HTTPError: 404: Not Found",
      executions_count: 1,
      finished_at: Time.current
    )
    step.update_column(:good_job_id, good_job.id)

    result = GoodPipeline::FailureMetadata.extract(step.reload)

    assert_equal "Net::HTTPError", result.error_class
    assert_equal "404: Not Found", result.error_message
  end

  def test_extract_handles_nil_error
    pipeline = create_pipeline
    step = build_step(pipeline, key: "a")

    good_job = GoodJob::Job.create!(
      id: SecureRandom.uuid,
      active_job_id: SecureRandom.uuid,
      job_class: "DownloadJob",
      error: nil,
      executions_count: 1,
      finished_at: Time.current
    )
    step.update_column(:good_job_id, good_job.id)

    result = GoodPipeline::FailureMetadata.extract(step.reload)

    assert_nil result.error_class
    assert_nil result.error_message
  end
end
