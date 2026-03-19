# frozen_string_literal: true

require "test_helper"

class TestEndToEnd < ActiveSupport::TestCase
  def run_pipeline_to_completion(pipeline_record, timeout: 15)
    deadline = Time.current + timeout
    loop do
      perform_enqueued_jobs_inline
      pipeline_record.reload
      return pipeline_record if pipeline_record.terminal?

      if Time.current > deadline
        raise "Pipeline did not reach terminal state within #{timeout}s (status: #{pipeline_record.status})"
      end

      sleep 0.05
    end
  end

  def test_full_pipeline_succeeds
    pipeline_record = VideoProcessingPipeline.run(video_id: 123)

    assert_instance_of GoodPipeline::PipelineRecord, pipeline_record
    assert_equal "VideoProcessingPipeline", pipeline_record.type
    assert_equal({ "video_id" => 123 }, pipeline_record.params)
    assert_equal 5, pipeline_record.steps.count
    assert_equal 5, pipeline_record.dependencies.count

    result = run_pipeline_to_completion(pipeline_record)

    assert_equal "succeeded", result.status
    assert(result.steps.all? { |step| step.coordination_status == "succeeded" })
    refute_nil result.callbacks_dispatched_at
  end

  def test_pipeline_with_failing_step_halts
    failing_pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt

      define_method(:configure) do |**_kwargs|
        run :step_a, FailingJob
        run :step_b, DownloadJob, after: :step_a
      end
    end
    Object.const_set(:HaltTestPipeline, failing_pipeline_class) unless defined?(::HaltTestPipeline)

    pipeline_record = HaltTestPipeline.run

    result = run_pipeline_to_completion(pipeline_record)

    assert_equal "halted", result.status
    assert_predicate result, :halt_triggered?

    step_a = result.steps.find_by(key: "step_a")
    step_b = result.steps.find_by(key: "step_b")

    assert_equal "failed", step_a.coordination_status
    assert_equal "skipped", step_b.coordination_status
  end

  def test_pipeline_with_continue_strategy
    continue_pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :continue

      define_method(:configure) do |**_kwargs|
        run :step_a, FailingJob
        run :step_b, DownloadJob
        run :step_c, DownloadJob, after: :step_a
      end
    end
    Object.const_set(:ContinueTestPipeline, continue_pipeline_class) unless defined?(::ContinueTestPipeline)

    pipeline_record = ContinueTestPipeline.run

    result = run_pipeline_to_completion(pipeline_record)

    assert_equal "failed", result.status
    refute_predicate result, :halt_triggered?

    step_a = result.steps.find_by(key: "step_a")
    step_b = result.steps.find_by(key: "step_b")
    step_c = result.steps.find_by(key: "step_c")

    assert_equal "failed", step_a.coordination_status
    assert_equal "succeeded", step_b.coordination_status
    assert_equal "skipped", step_c.coordination_status
  end
end
