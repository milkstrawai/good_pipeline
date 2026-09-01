# frozen_string_literal: true

require "test_helper"

class TestBulkEnqueue < ActiveSupport::TestCase
  # --- basic enqueuing ---

  def test_enqueues_multiple_steps
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "step_a", job_class: "DownloadJob")
    step_b = build_step(pipeline, key: "step_b", job_class: "TranscodeJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])

    step_a.reload
    step_b.reload

    assert_equal "enqueued", step_a.coordination_status
    assert_equal "enqueued", step_b.coordination_status
    refute_nil step_a.good_job_batch_id
    refute_nil step_b.good_job_batch_id
    refute_nil step_a.good_job_id
    refute_nil step_b.good_job_id
  end

  def test_each_step_gets_its_own_batch
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "step_a", job_class: "DownloadJob")
    step_b = build_step(pipeline, key: "step_b", job_class: "TranscodeJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])

    refute_equal step_a.reload.good_job_batch_id, step_b.reload.good_job_batch_id
  end

  def test_good_job_id_points_to_real_job_record
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "step_a", job_class: "DownloadJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    step.reload
    good_job = GoodJob::Job.find_by(id: step.good_job_id)

    refute_nil good_job, "good_job_id should point to a real GoodJob::Job record"
    assert_equal step.good_job_batch_id, good_job.batch_id
  end

  # --- batch callback setup ---

  def test_batch_has_step_finished_callback
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "step_a", job_class: "DownloadJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    batch_record = GoodJob::BatchRecord.find(step.reload.good_job_batch_id)

    assert_equal "GoodPipeline::StepFinishedJob", batch_record.on_finish
    assert_equal({ step_id: step.id, pipeline_id: pipeline.id }, batch_record.properties)
  end

  # --- enqueue_options ---

  def test_respects_queue_and_priority_options
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "step_a", job_class: "DownloadJob",
                      enqueue_options: { "queue" => "critical", "priority" => 3 })

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    good_job = GoodJob::Job.find_by(id: step.reload.good_job_id)

    assert_equal "critical", good_job.queue_name
    assert_equal 3, good_job.priority
  end

  def test_respects_wait_option
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "step_a", job_class: "DownloadJob",
                      enqueue_options: { "wait" => 300 })

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    good_job = GoodJob::Job.find_by(id: step.reload.good_job_id)

    refute_nil good_job.scheduled_at
    assert_in_delta 300, good_job.scheduled_at - good_job.created_at, 5
  end

  def test_passes_step_params_to_job
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "step_a", job_class: "DownloadJob",
                      params: { "video_id" => 42 })

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    good_job = GoodJob::Job.find_by(id: step.reload.good_job_id)
    arguments = good_job.serialized_params["arguments"]

    assert_equal 42, arguments.first["video_id"]
  end

  def test_handles_empty_params
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "step_a", job_class: "DownloadJob", params: {})

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    assert_equal "enqueued", step.reload.coordination_status
  end

  # --- guard clauses ---

  def test_skips_non_pending_steps
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "step_a", job_class: "DownloadJob")
    step_a.update_columns(coordination_status: "enqueued")
    step_b = build_step(pipeline, key: "step_b", job_class: "TranscodeJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])

    assert_equal "enqueued", step_b.reload.coordination_status
    refute_nil step_b.good_job_id
    assert_nil step_a.reload.good_job_id, "Non-pending step should not have been re-enqueued"
  end

  def test_skips_steps_with_good_job_id
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "step_a", job_class: "DownloadJob")
    existing_job_id = SecureRandom.uuid
    step_a.update_columns(good_job_id: existing_job_id)
    step_b = build_step(pipeline, key: "step_b", job_class: "TranscodeJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])

    assert_equal "enqueued", step_b.reload.coordination_status
    assert_equal existing_job_id, step_a.reload.good_job_id, "Step with good_job_id should be left alone"
  end

  def test_handles_empty_array
    # Should not raise
    result = GoodPipeline::Coordinator.bulk_enqueue_steps([])
    assert_nil result
  end

  def test_rejects_steps_from_multiple_pipelines_before_enqueuing
    pipeline_a = create_pipeline(on_failure_strategy: "halt", status: "running")
    pipeline_b = create_pipeline(on_failure_strategy: "halt", status: "running")
    step_a = build_step(pipeline_a, key: "step_a", job_class: "DownloadJob")
    step_b = build_step(pipeline_b, key: "step_b", job_class: "TranscodeJob")

    error = assert_raises(ArgumentError) do
      GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])
    end

    assert_match(/same pipeline/, error.message)
    assert_nil step_a.reload.good_job_id
    assert_nil step_b.reload.good_job_id
    assert_equal %w[pending pending], [step_a.coordination_status, step_b.coordination_status]
  end

  # --- branch step fallback ---

  def test_falls_back_to_try_enqueue_step_for_branch_steps
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    branch_step = build_step(pipeline, key: "format_check",
                             job_class: GoodPipeline::BRANCH_JOB_CLASS)
    branch_step.update_columns(branch: { "decides" => "pick_format", "empty_arms" => %w[hd sd] })
    normal_step = build_step(pipeline, key: "step_a", job_class: "DownloadJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([branch_step.id, normal_step.id])

    assert_equal "enqueued", normal_step.reload.coordination_status
    refute_nil normal_step.good_job_id

    branch_step.reload
    refute_equal "pending", branch_step.coordination_status,
                 "Branch step should have been processed by try_enqueue_step fallback"
  end

  # --- error handling ---

  def test_invalid_job_class_fails_step_without_blocking_others
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    bad_step = build_step(pipeline, key: "bad_step", job_class: "NonExistentJob")
    good_step = build_step(pipeline, key: "good_step", job_class: "DownloadJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([bad_step.id, good_step.id])

    assert_equal "enqueued", good_step.reload.coordination_status
    refute_nil good_step.good_job_id

    assert_equal "failed", bad_step.reload.coordination_status
    assert_equal "GoodPipeline::ConfigurationError", bad_step.error_class
  end

  def test_each_bulk_configuration_failure_applies_its_halt_scope
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    ignored_failure = build_step(
      pipeline,
      id: "00000000-0000-4000-8000-000000000001",
      key: "ignored_failure",
      job_class: "MissingIgnoredJob",
      on_failure_strategy: "ignore"
    )
    strict_failure = build_step(
      pipeline,
      id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      key: "strict_failure",
      job_class: "MissingStrictJob"
    )
    dependent = build_step(pipeline, key: "dependent", dependencies: [ignored_failure])

    GoodPipeline::Coordinator.bulk_enqueue_steps([ignored_failure.id, strict_failure.id])

    assert_equal "failed", ignored_failure.reload.coordination_status
    assert_equal "failed", strict_failure.reload.coordination_status
    assert_equal "skipped", dependent.reload.coordination_status
    assert_equal "halted", pipeline.reload.status
  end
end
