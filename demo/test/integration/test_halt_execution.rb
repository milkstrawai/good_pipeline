# frozen_string_literal: true

require "test_helper"

class TestHaltExecution < ActiveSupport::TestCase
  def run_pipeline_to_completion(pipeline_record, timeout: 15)
    deadline = Time.current + timeout
    loop do
      perform_enqueued_jobs_inline
      pipeline_record.reload
      return pipeline_record if pipeline_record.terminal?

      raise "Pipeline did not reach terminal state within #{timeout}s (status: #{pipeline_record.status})" if Time.current > deadline

      sleep 0.05
    end
  end

  def test_halt_pipeline_marks_step_halted
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt
      define_method(:configure) do |**|
        run :halt_step, HaltExecutionJob
        run :after_step, DownloadJob, after: :halt_step
      end
    end
    Object.const_set(:HaltSucceededPipeline, pipeline_class) unless defined?(::HaltSucceededPipeline)

    chain = HaltSucceededPipeline.run
    result = run_pipeline_to_completion(chain)

    halt_step = result.steps.find_by(key: "halt_step")
    assert_equal "halted", halt_step.coordination_status
    assert halt_step.halt_requested?, "halt_requested should be true"
  end

  def test_halt_pipeline_skips_remaining_steps
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt
      define_method(:configure) do |**|
        run :halt_step, HaltExecutionJob
        run :after_step, DownloadJob, after: :halt_step
      end
    end
    Object.const_set(:HaltSkipsPipeline, pipeline_class) unless defined?(::HaltSkipsPipeline)

    chain = HaltSkipsPipeline.run
    result = run_pipeline_to_completion(chain)

    after_step = result.steps.find_by(key: "after_step")
    assert_equal "skipped", after_step.coordination_status
  end

  def test_halt_pipeline_pipeline_succeeds
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt
      define_method(:configure) do |**|
        run :halt_step, HaltExecutionJob
        run :after_step, DownloadJob, after: :halt_step
      end
    end
    Object.const_set(:HaltSucceedsPipeline, pipeline_class) unless defined?(::HaltSucceedsPipeline)

    chain = HaltSucceedsPipeline.run
    result = run_pipeline_to_completion(chain)

    assert_equal "succeeded", result.status
  end

  def test_halt_pipeline_job_succeeds_in_good_job
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt
      define_method(:configure) do |**|
        run :halt_step, HaltExecutionJob
      end
    end
    Object.const_set(:HaltJobSucceedsPipeline, pipeline_class) unless defined?(::HaltJobSucceedsPipeline)

    chain = HaltJobSucceedsPipeline.run
    run_pipeline_to_completion(chain)

    halt_step = chain.steps.find_by(key: "halt_step")
    good_job = GoodJob::Job.find(halt_step.good_job_id)

    assert_equal 1, good_job.executions_count
    assert_nil good_job.error, "GoodJob record should have no error"
    assert_not_nil good_job.finished_at
  end

  def test_halt_pipeline_with_parallel_steps
    pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :continue
      define_method(:configure) do |**|
        run :halt_step, HaltExecutionJob
        run :normal_step, DownloadJob
        run :after_both, CleanupJob, after: %i[halt_step normal_step]
      end
    end
    Object.const_set(:HaltParallelPipeline, pipeline_class) unless defined?(::HaltParallelPipeline)

    chain = HaltParallelPipeline.run
    result = run_pipeline_to_completion(chain)

    halt_step = result.steps.find_by(key: "halt_step")
    normal_step = result.steps.find_by(key: "normal_step")
    after_both = result.steps.find_by(key: "after_both")

    assert_equal "halted", halt_step.coordination_status
    assert_equal "succeeded", normal_step.coordination_status
    assert_equal "skipped", after_both.coordination_status
    assert_equal "succeeded", result.status
  end
end
