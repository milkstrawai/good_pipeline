# frozen_string_literal: true

require "test_helper"

class TestQueueConfiguration < ActiveSupport::TestCase
  teardown do
    GoodPipeline.coordination_queue_name = nil
    GoodPipeline.callback_queue_name = nil
  end

  # --- global defaults ---

  def test_default_coordination_queue_name
    assert_equal "good_pipeline_coordination", GoodPipeline.coordination_queue_name
  end

  def test_default_callback_queue_name
    assert_equal "good_pipeline_callbacks", GoodPipeline.callback_queue_name
  end

  # --- global override ---

  def test_global_coordination_queue_override
    GoodPipeline.coordination_queue_name = "custom_coordination"

    assert_equal "custom_coordination", GoodPipeline.coordination_queue_name
  end

  def test_global_callback_queue_override
    GoodPipeline.callback_queue_name = "custom_callbacks"

    assert_equal "custom_callbacks", GoodPipeline.callback_queue_name
  end

  # --- pipeline DSL ---

  def test_pipeline_dsl_coordination_queue
    klass = Class.new(GoodPipeline::Pipeline) do
      coordination_queue_name "pipeline_coordination"
      def configure(**) = run(:a, DownloadJob)
    end

    assert_equal "pipeline_coordination", klass.coordination_queue_name
  end

  def test_pipeline_dsl_callback_queue
    klass = Class.new(GoodPipeline::Pipeline) do
      callback_queue_name "pipeline_callbacks"
      def configure(**) = run(:a, DownloadJob)
    end

    assert_equal "pipeline_callbacks", klass.callback_queue_name
  end

  # --- pipeline DSL fallback to global ---

  def test_pipeline_without_dsl_uses_global_config
    GoodPipeline.coordination_queue_name = "global_coordination"

    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, DownloadJob)
    end

    assert_equal "global_coordination", klass.coordination_queue_name
  end

  def test_pipeline_without_dsl_or_global_uses_default
    klass = Class.new(GoodPipeline::Pipeline) do
      def configure(**) = run(:a, DownloadJob)
    end

    assert_equal "good_pipeline_coordination", klass.coordination_queue_name
  end

  # --- pipeline DSL overrides global ---

  def test_pipeline_dsl_overrides_global
    GoodPipeline.coordination_queue_name = "global_coordination"

    klass = Class.new(GoodPipeline::Pipeline) do
      coordination_queue_name "pipeline_coordination"
      def configure(**) = run(:a, DownloadJob)
    end

    assert_equal "pipeline_coordination", klass.coordination_queue_name
  end

  # --- inheritance ---

  def test_pipeline_inherits_queue_from_parent
    parent = Class.new(GoodPipeline::Pipeline) do
      coordination_queue_name "parent_coordination"
      callback_queue_name "parent_callbacks"
    end

    child = Class.new(parent) do
      def configure(**) = run(:a, DownloadJob)
    end

    assert_equal "parent_coordination", child.coordination_queue_name
    assert_equal "parent_callbacks", child.callback_queue_name
  end

  # --- step batch gets coordination queue ---

  def test_step_batch_gets_coordination_queue
    klass = Class.new(GoodPipeline::Pipeline) do
      coordination_queue_name "step_coordination"
      def configure(**) = run(:a, DownloadJob)
    end
    klass.define_singleton_method(:name) { "StepBatchQueueTestPipeline" }
    Object.const_set(:StepBatchQueueTestPipeline, klass) unless defined?(::StepBatchQueueTestPipeline)

    pipeline_record = StepBatchQueueTestPipeline.run

    step = pipeline_record.steps.first
    batch_record = GoodJob::BatchRecord.find(step.good_job_batch_id)

    assert_equal "step_coordination", batch_record.callback_queue_name
  end

  # --- pipeline batch gets coordination queue ---

  def test_pipeline_batch_gets_coordination_queue
    klass = Class.new(GoodPipeline::Pipeline) do
      coordination_queue_name "pipeline_coordination"
      def configure(**) = run(:a, DownloadJob)
    end
    klass.define_singleton_method(:name) { "PipelineBatchQueueTestPipeline" }
    Object.const_set(:PipelineBatchQueueTestPipeline, klass) unless defined?(::PipelineBatchQueueTestPipeline)

    pipeline_record = PipelineBatchQueueTestPipeline.run

    actual_record = GoodPipeline::PipelineRecord.find(pipeline_record.id)
    batch_record = GoodJob::BatchRecord.find(actual_record.good_job_batch_id)

    assert_equal "pipeline_coordination", batch_record.callback_queue_name
  end

  # --- PipelineCallbackJob gets callback queue ---

  def test_callback_job_gets_callback_queue
    klass = Class.new(GoodPipeline::Pipeline) do
      callback_queue_name "my_callbacks"
      def configure(**) = run(:a, DownloadJob)
    end
    klass.define_singleton_method(:name) { "CallbackQueueTestPipeline" }
    Object.const_set(:CallbackQueueTestPipeline, klass) unless defined?(::CallbackQueueTestPipeline)

    pipeline_record = CallbackQueueTestPipeline.run
    run_pipeline_to_completion(pipeline_record)

    callback_job = GoodJob::Job.where(job_class: "GoodPipeline::PipelineCallbackJob").last

    assert_equal "my_callbacks", callback_job.queue_name
  end
end
