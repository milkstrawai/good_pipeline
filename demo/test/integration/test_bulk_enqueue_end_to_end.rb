# frozen_string_literal: true

require "test_helper"

class TestBulkEnqueueEndToEnd < ActiveSupport::TestCase
  def test_fan_in_pipeline_with_multiple_root_steps_succeeds
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt

      define_method(:configure) do |**_kwargs|
        run :root_a, DownloadJob
        run :root_b, TranscodeJob
        run :root_c, ThumbnailJob
        run :collector, PublishJob, after: %i[root_a root_b root_c]
      end
    end
    Object.const_set(:FanInBulkTestPipeline, pipeline_class) unless defined?(::FanInBulkTestPipeline)

    pipeline_record = FanInBulkTestPipeline.run

    # All 3 root steps should have been enqueued with distinct batches
    root_steps = pipeline_record.steps.where(key: %w[root_a root_b root_c])
    root_steps.each do |step|
      refute_equal "pending", step.coordination_status,
                   "Root step #{step.key} should have been enqueued"
      refute_nil step.good_job_batch_id
      refute_nil step.good_job_id
    end

    batch_ids = root_steps.pluck(:good_job_batch_id).uniq
    assert_equal 3, batch_ids.size, "Each root step should have a unique batch"

    result = run_pipeline_to_completion(pipeline_record)

    assert_equal "succeeded", result.status
    assert(result.steps.all? { |step| step.coordination_status == "succeeded" })
  end

  def test_all_root_steps_pipeline_succeeds
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :continue

      define_method(:configure) do |**_kwargs|
        run :step_a, DownloadJob
        run :step_b, TranscodeJob
        run :step_c, ThumbnailJob
        run :step_d, PublishJob
        run :step_e, CleanupJob
      end
    end
    Object.const_set(:AllRootsBulkTestPipeline, pipeline_class) unless defined?(::AllRootsBulkTestPipeline)

    pipeline_record = AllRootsBulkTestPipeline.run
    result = run_pipeline_to_completion(pipeline_record)

    assert_equal "succeeded", result.status

    result.steps.each do |step|
      assert_equal "succeeded", step.coordination_status
      refute_nil step.good_job_batch_id
      refute_nil step.good_job_id
    end
  end

  def test_fan_in_with_failing_root_step_halts
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt

      define_method(:configure) do |**_kwargs|
        run :root_a, DownloadJob
        run :root_b, FailingJob
        run :root_c, ThumbnailJob
        run :collector, PublishJob, after: %i[root_a root_b root_c]
      end
    end
    Object.const_set(:FanInFailBulkTestPipeline, pipeline_class) unless defined?(::FanInFailBulkTestPipeline)

    pipeline_record = FanInFailBulkTestPipeline.run
    result = run_pipeline_to_completion(pipeline_record)

    assert_equal "halted", result.status
    assert_equal "failed", result.steps.find_by(key: "root_b").coordination_status
  end

  def test_enqueue_options_forwarded_to_good_job
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt

      define_method(:configure) do |**_kwargs|
        run :step_a, DownloadJob, enqueue: { queue: "critical", priority: 1 }
        run :step_b, TranscodeJob, enqueue: { queue: "low", priority: 10 }
      end
    end
    Object.const_set(:EnqueueOptionsBulkTestPipeline, pipeline_class) unless defined?(::EnqueueOptionsBulkTestPipeline)

    pipeline_record = EnqueueOptionsBulkTestPipeline.run

    step_a = pipeline_record.steps.find_by(key: "step_a")
    step_b = pipeline_record.steps.find_by(key: "step_b")

    good_job_a = GoodJob::Job.find_by(id: step_a.good_job_id)
    good_job_b = GoodJob::Job.find_by(id: step_b.good_job_id)

    assert_equal "critical", good_job_a.queue_name
    assert_equal 1, good_job_a.priority
    assert_equal "low", good_job_b.queue_name
    assert_equal 10, good_job_b.priority
  end
end
