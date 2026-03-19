# frozen_string_literal: true

require "active_record_test_helper"

class TestRunner < Minitest::Test
  include ActiveRecordTestCase

  DownloadJob = Class.new
  TranscodeJob = Class.new
  ThumbnailJob = Class.new

  TestPipeline = Class.new(GoodPipeline::Pipeline) do
    description "Test pipeline"
    failure_strategy :halt

    define_method(:configure) do |video_id:, **|
      run :download, TestRunner::DownloadJob, with: { video_id: video_id }
      run :transcode, TestRunner::TranscodeJob, after: :download
      run :thumbnail, TestRunner::ThumbnailJob, after: :download
    end
  end

  def test_creates_pipeline_record
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    mock_batch = MockBatch.new
    GoodJob::Batch.stub(:new, mock_batch) do
      GoodPipeline::Coordinator.stub(:try_enqueue_step, nil) do
        record = GoodPipeline::Runner.call(instance)

        assert_instance_of GoodPipeline::PipelineRecord, record
        assert_equal klass.name, record.type
        assert_equal({ "video_id" => 42 }, record.params)
        assert_equal "running", record.status
        assert_equal "halt", record.on_failure_strategy
      end
    end
  end

  def test_creates_step_records
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    mock_batch = MockBatch.new
    GoodJob::Batch.stub(:new, mock_batch) do
      GoodPipeline::Coordinator.stub(:try_enqueue_step, nil) do
        record = GoodPipeline::Runner.call(instance)

        steps = record.steps.order(:key)
        assert_equal 3, steps.count
        assert_equal %w[download thumbnail transcode], steps.map(&:key)
        assert_equal "TestRunner::DownloadJob", steps.find_by(key: "download").job_class
        assert_equal({ "video_id" => 42 }, steps.find_by(key: "download").params)
      end
    end
  end

  def test_creates_dependency_records
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    mock_batch = MockBatch.new
    GoodJob::Batch.stub(:new, mock_batch) do
      GoodPipeline::Coordinator.stub(:try_enqueue_step, nil) do
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
    end
  end

  def test_enqueues_root_steps
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    enqueued_step_ids = []
    mock_batch = MockBatch.new
    GoodJob::Batch.stub(:new, mock_batch) do
      GoodPipeline::Coordinator.stub(:try_enqueue_step, ->(id) { enqueued_step_ids << id }) do
        record = GoodPipeline::Runner.call(instance)

        download = record.steps.find_by(key: "download")
        assert_equal [download.id], enqueued_step_ids
      end
    end
  end

  def test_stores_pipeline_batch_id
    klass = TestPipeline
    instance = klass.build(video_id: 42)

    mock_batch = MockBatch.new
    GoodJob::Batch.stub(:new, mock_batch) do
      GoodPipeline::Coordinator.stub(:try_enqueue_step, nil) do
        record = GoodPipeline::Runner.call(instance)

        assert_equal mock_batch.id, record.good_job_batch_id
      end
    end
  end
end
