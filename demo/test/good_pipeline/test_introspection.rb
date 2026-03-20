# frozen_string_literal: true

require "test_helper"

class TestIntrospection < ActiveSupport::TestCase
  def test_duration_returns_seconds_from_good_job
    pipeline = create_pipeline
    step = create_step(pipeline, key: "a")

    performed_at = 10.seconds.ago
    finished_at = Time.current
    good_job = GoodJob::Job.create!(
      id: SecureRandom.uuid,
      active_job_id: SecureRandom.uuid,
      job_class: "DownloadJob",
      performed_at: performed_at,
      finished_at: finished_at
    )
    step.update_column(:good_job_id, good_job.id)

    assert_in_delta 10.0, step.duration, 0.5
  end

  def test_duration_returns_nil_when_no_good_job_id
    pipeline = create_pipeline
    step = create_step(pipeline, key: "a")

    assert_nil step.duration
  end

  def test_duration_returns_nil_when_good_job_not_performed
    pipeline = create_pipeline
    step = create_step(pipeline, key: "a")

    good_job = GoodJob::Job.create!(
      id: SecureRandom.uuid,
      active_job_id: SecureRandom.uuid,
      job_class: "DownloadJob",
      performed_at: nil,
      finished_at: nil
    )
    step.update_column(:good_job_id, good_job.id)

    assert_nil step.duration
  end
end
