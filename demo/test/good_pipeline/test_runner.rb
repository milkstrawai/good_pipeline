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

  BarrierPipeline = Class.new(GoodPipeline::Pipeline) do
    def configure(**)
      run :fetch_a, DownloadJob
      run :fetch_b, DownloadJob
      barrier
      run :publish, PublishJob
    end
  end

  DuplicateDependencyPipeline = Class.new(GoodPipeline::Pipeline) do
    def configure(**)
      run :fetch, DownloadJob
      run :publish, PublishJob, after: %i[fetch fetch]
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

  def test_creates_dependency_records # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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

  def test_persists_barrier_as_structural_step_with_correct_counters # rubocop:disable Metrics/AbcSize
    record = GoodPipeline::Runner.call(BarrierPipeline.build, start: false)
    barrier = record.steps.find_by!(job_class: GoodPipeline::BARRIER_JOB_CLASS)
    publish = record.steps.find_by!(key: "publish")

    assert_equal "pending", barrier.coordination_status
    assert_equal 2, barrier.pending_upstream_count
    assert_equal 1, publish.pending_upstream_count
    assert_nil barrier.good_job_id
    assert_nil barrier.good_job_batch_id
    assert_equal 3, record.dependencies.count
    refute_includes record.steps.where.missing(:upstream_dependencies).pluck(:id), barrier.id
  end

  def test_persists_duplicate_authored_dependency_once_without_barrier
    record = GoodPipeline::Runner.call(DuplicateDependencyPipeline.build, start: false)
    publish = record.steps.find_by!(key: "publish")

    assert_equal 1, publish.pending_upstream_count
    assert_equal 1, record.dependencies.where(step: publish).count
  end
end
