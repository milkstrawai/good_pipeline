# frozen_string_literal: true

require "test_helper"

class TestPipelineCallbackJob < ActiveSupport::TestCase
  def setup
    super
    @callback_log = []
  end

  def build_pipeline_class(on_complete: nil, on_success: nil, on_failure: nil)
    log = @callback_log
    Class.new(GoodPipeline::Pipeline) do
      self.on_complete(on_complete) if on_complete
      self.on_success(on_success) if on_success
      self.on_failure(on_failure) if on_failure

      define_method(:notify_complete) { log << :on_complete }
      define_method(:notify_success) { log << :on_success }
      define_method(:notify_failure) { log << :on_failure }

      def configure(**) = run(:a, Class.new)
    end
  end

  def test_calls_on_complete_and_on_success_for_succeeded
    klass = build_pipeline_class(on_complete: :notify_complete, on_success: :notify_success)
    # We need a named class for constantize to work
    self.class.const_set(:SucceededPipeline, klass) unless self.class.const_defined?(:SucceededPipeline)

    pipeline = create_pipeline(type: self.class::SucceededPipeline.name)
    job = GoodPipeline::PipelineCallbackJob.new
    job.perform(pipeline.id, "succeeded")

    assert_includes @callback_log, :on_complete
    assert_includes @callback_log, :on_success
    refute_includes @callback_log, :on_failure
  end

  def test_calls_on_complete_and_on_failure_for_failed
    klass = build_pipeline_class(on_complete: :notify_complete, on_failure: :notify_failure)
    self.class.const_set(:FailedPipeline, klass) unless self.class.const_defined?(:FailedPipeline)

    pipeline = create_pipeline(type: self.class::FailedPipeline.name)
    job = GoodPipeline::PipelineCallbackJob.new
    job.perform(pipeline.id, "failed")

    assert_includes @callback_log, :on_complete
    assert_includes @callback_log, :on_failure
    refute_includes @callback_log, :on_success
  end

  def test_calls_on_complete_and_on_failure_for_halted
    klass = build_pipeline_class(on_complete: :notify_complete, on_failure: :notify_failure)
    self.class.const_set(:HaltedPipeline, klass) unless self.class.const_defined?(:HaltedPipeline)

    pipeline = create_pipeline(type: self.class::HaltedPipeline.name)
    job = GoodPipeline::PipelineCallbackJob.new
    job.perform(pipeline.id, "halted")

    assert_includes @callback_log, :on_complete
    assert_includes @callback_log, :on_failure
  end

  def test_handles_nil_callbacks_gracefully
    klass = build_pipeline_class
    self.class.const_set(:NilCallbackPipeline, klass) unless self.class.const_defined?(:NilCallbackPipeline)

    pipeline = create_pipeline(type: self.class::NilCallbackPipeline.name)
    job = GoodPipeline::PipelineCallbackJob.new
    job.perform(pipeline.id, "succeeded")

    assert_empty @callback_log
  end
end
