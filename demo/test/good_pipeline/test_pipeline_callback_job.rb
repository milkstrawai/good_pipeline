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

  def test_rejects_invalid_terminal_status
    klass = build_pipeline_class
    self.class.const_set(:InvalidStatusPipeline, klass) unless self.class.const_defined?(:InvalidStatusPipeline)

    pipeline = create_pipeline(type: self.class::InvalidStatusPipeline.name)
    job = GoodPipeline::PipelineCallbackJob.new

    assert_raises(ArgumentError) { job.perform(pipeline.id, "invalid") }
    assert_raises(ArgumentError) { job.perform(pipeline.id, "pending") }
  end

  def test_error_in_callback_is_raised
    log = @callback_log
    klass = Class.new(GoodPipeline::Pipeline) do
      on_complete(:exploding_callback)

      define_method(:exploding_callback) do
        log << :exploded
        raise StandardError, "callback exploded"
      end

      def configure(**) = run(:a, Class.new)
    end
    self.class.const_set(:ExplodingPipeline, klass) unless self.class.const_defined?(:ExplodingPipeline)

    pipeline = create_pipeline(type: self.class::ExplodingPipeline.name)
    job = GoodPipeline::PipelineCallbackJob.new

    error = assert_raises(StandardError) { job.perform(pipeline.id, "succeeded") }
    assert_equal "callback exploded", error.message
    assert_includes @callback_log, :exploded
  end

  def test_error_in_first_callback_still_runs_second
    log = @callback_log
    klass = Class.new(GoodPipeline::Pipeline) do
      on_complete(:exploding_complete)
      on_success(:record_success)

      define_method(:exploding_complete) do
        log << :complete_exploded
        raise StandardError, "complete exploded"
      end
      define_method(:record_success) { log << :success_recorded }

      def configure(**) = run(:a, Class.new)
    end
    self.class.const_set(:BothCallbacksPipeline, klass) unless self.class.const_defined?(:BothCallbacksPipeline)

    pipeline = create_pipeline(type: self.class::BothCallbacksPipeline.name)
    job = GoodPipeline::PipelineCallbackJob.new

    assert_raises(StandardError) { job.perform(pipeline.id, "succeeded") }
    assert_includes @callback_log, :complete_exploded
    assert_includes @callback_log, :success_recorded
  end
end
