# frozen_string_literal: true

require "test_helper"

class TestQueueConfigurationEndToEnd < ActiveSupport::TestCase
  teardown do
    GoodPipeline.coordination_queue_name = nil
    GoodPipeline.callback_queue_name = nil
  end

  def test_full_pipeline_with_custom_queues
    klass = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt
      coordination_queue_name "e2e_coordination"
      callback_queue_name "e2e_callbacks"

      define_method(:configure) do |**_kwargs|
        run :step_a, DownloadJob
        run :step_b, TranscodeJob
        run :step_c, PublishJob, after: %i[step_a step_b]
      end
    end
    klass.define_singleton_method(:name) { "QueueE2ETestPipeline" }
    Object.const_set(:QueueE2ETestPipeline, klass) unless defined?(::QueueE2ETestPipeline)

    pipeline_record = QueueE2ETestPipeline.run

    # Verify step batch queue names
    pipeline_record.steps.each do |step|
      next unless step.good_job_batch_id

      batch_record = GoodJob::BatchRecord.find(step.good_job_batch_id)

      assert_equal "e2e_coordination", batch_record.callback_queue_name,
                   "Step #{step.key} batch should use coordination queue"
    end

    # Verify pipeline batch queue name
    actual_record = GoodPipeline::PipelineRecord.find(pipeline_record.id)
    pipeline_batch = GoodJob::BatchRecord.find(actual_record.good_job_batch_id)

    assert_equal "e2e_coordination", pipeline_batch.callback_queue_name

    # Run to completion and verify callback job queue
    result = run_pipeline_to_completion(pipeline_record)

    assert_equal "succeeded", result.status

    callback_job = GoodJob::Job.where(job_class: "GoodPipeline::PipelineCallbackJob").last

    assert_equal "e2e_callbacks", callback_job.queue_name
  end

  def test_global_config_applies_when_no_dsl
    GoodPipeline.coordination_queue_name = "global_coord"
    GoodPipeline.callback_queue_name = "global_cb"

    klass = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt
      define_method(:configure) do |**_kwargs|
        run :step_a, DownloadJob
      end
    end
    klass.define_singleton_method(:name) { "GlobalQueueTestPipeline" }
    Object.const_set(:GlobalQueueTestPipeline, klass) unless defined?(::GlobalQueueTestPipeline)

    pipeline_record = GlobalQueueTestPipeline.run

    step = pipeline_record.steps.first
    step_batch = GoodJob::BatchRecord.find(step.good_job_batch_id)

    assert_equal "global_coord", step_batch.callback_queue_name

    result = run_pipeline_to_completion(pipeline_record)

    assert_equal "succeeded", result.status

    callback_job = GoodJob::Job.where(job_class: "GoodPipeline::PipelineCallbackJob").last

    assert_equal "global_cb", callback_job.queue_name
  end
end
