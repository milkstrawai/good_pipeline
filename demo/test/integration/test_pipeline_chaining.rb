# frozen_string_literal: true

require "test_helper"

class TestPipelineChaining < ActiveSupport::TestCase
  def run_all_to_completion(pipeline_records, timeout: 15)
    deadline = Time.current + timeout
    loop do
      perform_enqueued_jobs_inline
      pipeline_records.each(&:reload)
      return pipeline_records if pipeline_records.all?(&:terminal?)

      if Time.current > deadline
        statuses = pipeline_records.map { |pipeline| "#{pipeline.type}=#{pipeline.status}" }.join(", ")
        raise "Pipelines did not reach terminal state within #{timeout}s (#{statuses})"
      end

      sleep 0.05
    end
  end

  # --- Serial chain ---

  def test_serial_chain_all_succeed
    TestPipeline.run(video_id: 1)
                .then(NotificationPipeline, with: { video_id: 1 })
                .then(ArchivePipeline, with: { video_id: 1 })

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    assert all_records.all?(&:succeeded?), "All pipelines should have succeeded"
  end

  def test_serial_chain_first_fails_skips_rest
    HaltTestPipeline.run
                    .then(NotificationPipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    upstream = all_records.find { |pipeline| pipeline.type == "HaltTestPipeline" }
    downstream = all_records.find { |pipeline| pipeline.type == "NotificationPipeline" }

    assert_equal "halted", upstream.status
    assert_equal "skipped", downstream.status
  end

  # --- Fan-out ---

  def test_fan_out_both_start_after_upstream_succeeds
    TestPipeline.run(video_id: 1)
                .then(
                  [NotificationPipeline, { with: {} }],
                  [AnalyticsPipeline, { with: {} }]
                )

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    notification = all_records.find { |pipeline| pipeline.type == "NotificationPipeline" }
    analytics = all_records.find { |pipeline| pipeline.type == "AnalyticsPipeline" }

    assert_equal "succeeded", notification.status
    assert_equal "succeeded", analytics.status
  end

  def test_fan_out_upstream_fails_skips_all_downstream
    HaltTestPipeline.run
                    .then(
                      [NotificationPipeline, { with: {} }],
                      [AnalyticsPipeline, { with: {} }]
                    )

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    notification = all_records.find { |pipeline| pipeline.type == "NotificationPipeline" }
    analytics = all_records.find { |pipeline| pipeline.type == "AnalyticsPipeline" }

    assert_equal "skipped", notification.status
    assert_equal "skipped", analytics.status
  end

  # --- Fan-in ---

  def test_fan_in_waits_for_all_upstreams
    GoodPipeline.run(
      [TestPipeline, { with: { video_id: 1 } }],
      [NotificationPipeline, { with: {} }]
    ).then(ArchivePipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    archive = all_records.find { |pipeline| pipeline.type == "ArchivePipeline" }

    assert_equal "succeeded", archive.status
  end

  def test_fan_in_skips_when_any_upstream_fails
    failing_pipeline_class = Class.new(GoodPipeline::Pipeline) do
      failure_strategy :halt
      define_method(:configure) { |**_kwargs| run :fail_step, FailingJob }
    end
    Object.const_set(:FanInFailPipeline, failing_pipeline_class) unless defined?(::FanInFailPipeline)

    GoodPipeline.run(
      [TestPipeline, { with: { video_id: 1 } }],
      [FanInFailPipeline, { with: {} }]
    ).then(ArchivePipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    archive = all_records.find { |pipeline| pipeline.type == "ArchivePipeline" }

    assert_equal "skipped", archive.status
  end

  # --- Fan-out then fan-in ---

  def test_fan_out_then_fan_in
    TestPipeline.run(video_id: 1)
                .then(
                  [NotificationPipeline, { with: {} }],
                  [AnalyticsPipeline, { with: {} }]
                )
                .then(ArchivePipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    assert all_records.all?(&:succeeded?), "All pipelines should have succeeded"

    archive = all_records.find { |pipeline| pipeline.type == "ArchivePipeline" }

    assert_equal 2, archive.upstream_pipelines.count
  end

  # --- Deep chain failure propagation ---

  def test_deep_chain_failure_propagates_skips
    HaltTestPipeline.run
                    .then(NotificationPipeline, with: {})
                    .then(AnalyticsPipeline, with: {})
                    .then(ArchivePipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    notification = all_records.find { |pipeline| pipeline.type == "NotificationPipeline" }
    analytics = all_records.find { |pipeline| pipeline.type == "AnalyticsPipeline" }
    archive = all_records.find { |pipeline| pipeline.type == "ArchivePipeline" }

    assert_equal "skipped", notification.status
    assert_equal "skipped", analytics.status
    assert_equal "skipped", archive.status
  end

  # --- Callbacks on skipped ---

  def test_skipped_pipeline_fires_on_complete_but_not_on_failure
    callback_pipeline_class = Class.new(GoodPipeline::Pipeline) do
      on_complete :handle_complete

      define_method(:configure) { |**_kwargs| run :step, DownloadJob }
      define_method(:handle_complete) {} # no-op
    end
    Object.const_set(:SkipCallbackPipeline, callback_pipeline_class) unless defined?(::SkipCallbackPipeline)

    HaltTestPipeline.run
                    .then(SkipCallbackPipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    skipped_pipeline = all_records.find { |pipeline| pipeline.type == "SkipCallbackPipeline" }

    assert_equal "skipped", skipped_pipeline.status
    assert_not_nil skipped_pipeline.callbacks_dispatched_at
  end
end
