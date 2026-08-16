# frozen_string_literal: true

require "test_helper"

class TestRunner < ActiveSupport::TestCase
  TestPipeline = Class.new(GoodPipeline::Pipeline) do
    description "Test pipeline"
    failure_strategy :halt

    define_method(:configure) do |video_id:, **|
      run :download, DownloadJob, with: { video_id: video_id }
      run :transcode, TranscodeJob, after: :download
      run :thumbnail, ThumbnailJob, after: :download
    end
  end

  def test_creates_pipeline_record
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    record = GoodPipeline::Runner.call(instance)

    assert_instance_of GoodPipeline::PipelineRecord, record
    assert_equal klass.name, record.type
    assert_equal({ "video_id" => 42 }, record.params)
    assert_equal "running", record.status
    assert_equal "halt", record.on_failure_strategy
  end

  def test_creates_step_records
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    record = GoodPipeline::Runner.call(instance)

    steps = record.steps.order(:key)

    assert_equal 3, steps.count
    assert_equal %w[download thumbnail transcode], steps.map(&:key)
    assert_equal "DownloadJob", steps.find_by(key: "download").job_class
    assert_equal({ "video_id" => 42 }, steps.find_by(key: "download").params)
  end

  def test_creates_dependency_records
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    record = GoodPipeline::Runner.call(instance)

    deps = record.dependencies

    assert_equal 2, deps.count

    download = record.steps.find_by(key: "download")
    transcode = record.steps.find_by(key: "transcode")
    thumbnail = record.steps.find_by(key: "thumbnail")

    transcode_dep = deps.find_by(step: transcode)

    assert_equal download.id, transcode_dep.depends_on_step_id

    thumbnail_dep = deps.find_by(step: thumbnail)

    assert_equal download.id, thumbnail_dep.depends_on_step_id
  end

  def test_enqueues_root_steps
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    record = GoodPipeline::Runner.call(instance)

    download = record.steps.find_by(key: "download")
    # Root step should have been enqueued (may have already completed)
    refute_equal "pending", download.reload.coordination_status
  end

  def test_stores_pipeline_batch_id
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    record = GoodPipeline::Runner.call(instance)

    assert_not_nil record.good_job_batch_id
  end

  def test_post_persistence_start_error_retains_the_created_pipeline_identity_and_cause
    instance = TestPipeline.build(video_id: 42)
    original_error = RuntimeError.new("database unavailable: password=do-not-expose")

    error = assert_raises(GoodPipeline::PipelineStartError) do
      with_stubbed_singleton_method(
        GoodPipeline::Coordinator,
        :bulk_enqueue_steps,
        ->(_step_ids) { raise original_error }
      ) do
        GoodPipeline::Runner.call(instance)
      end
    end

    pipeline = GoodPipeline::PipelineRecord.find(error.pipeline_id)

    assert_same original_error, error.original_error
    assert_same original_error, error.cause
    refute_includes error.message, original_error.message
    assert_equal 3, pipeline.steps.count
    assert_equal 2, pipeline.dependencies.count
    assert GoodJob::BatchRecord.exists?(pipeline.good_job_batch_id)
  end

  def test_good_job_insertion_failure_is_not_recorded_as_a_user_step_failure
    instance = TestPipeline.build(video_id: 42)
    original_error = ActiveRecord::ConnectionNotEstablished.new("injected GoodJob insertion outage")

    error = assert_raises(GoodPipeline::PipelineStartError) do
      with_stubbed_singleton_method(
        GoodJob::Batch,
        :enqueue_all,
        ->(_batch_job_pairs) { raise original_error }
      ) do
        GoodPipeline::Runner.call(instance)
      end
    end

    pipeline = GoodPipeline::PipelineRecord.find(error.pipeline_id)

    assert_same original_error, error.original_error
    assert_same original_error, error.cause
    assert_equal "running", pipeline.status
    assert pipeline.steps.all?(&:pending?)
    assert pipeline.steps.all? { |step| step.error_class.nil? && step.error_message.nil? }
    assert_equal 0, GoodJob::Job.where(job_class: %w[DownloadJob TranscodeJob ThumbnailJob]).count
  end

  def test_reconciliation_adapter_is_validated_before_graph_or_batch_persistence
    instance = TestPipeline.build(video_id: 42)
    original_adapter = GoodPipeline::PipelineReconciliationJob.queue_adapter
    pipeline_count = GoodPipeline::PipelineRecord.count
    batch_count = GoodJob::BatchRecord.count
    GoodPipeline::PipelineReconciliationJob.queue_adapter = ActiveJob::QueueAdapters::TestAdapter.new

    error = assert_raises(GoodPipeline::ConfigurationError) do
      GoodPipeline::Runner.call(instance)
    end

    assert_match(/requires a GoodJob adapter/, error.message)
    assert_equal pipeline_count, GoodPipeline::PipelineRecord.count
    assert_equal batch_count, GoodJob::BatchRecord.count
  ensure
    GoodPipeline::PipelineReconciliationJob.queue_adapter = original_adapter if original_adapter
  end
end
