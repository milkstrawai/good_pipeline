# frozen_string_literal: true

require "test_helper"

class TestLateChainRegistration < ActiveSupport::TestCase
  def test_then_called_after_upstream_completes_still_starts_downstream
    chain = TestPipeline.run(video_id: 1)
    perform_enqueued_jobs_inline

    upstream = chain.reload
    assert_equal "succeeded", upstream.status, "Upstream should have already completed"

    chain.then(NotificationPipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    downstream = all_records.find { |pipeline| pipeline.type == "NotificationPipeline" }

    assert_equal "succeeded", downstream.status,
                 "Downstream registered after upstream completion should still start and succeed"
  end

  def test_then_called_after_upstream_fails_skips_downstream
    chain = HaltTestPipeline.run
    perform_enqueued_jobs_inline

    upstream = chain.reload
    assert_predicate upstream, :terminal?, "Upstream should have already completed"

    chain.then(NotificationPipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    downstream = all_records.find { |pipeline| pipeline.type == "NotificationPipeline" }

    assert_equal "skipped", downstream.status,
                 "Downstream registered after upstream failure should be skipped"
  end

  def test_then_called_after_fan_out_both_complete_starts_fan_in
    chain = GoodPipeline.run(
      [TestPipeline, { with: { video_id: 1 } }],
      [AnalyticsPipeline, { with: {} }]
    )
    perform_enqueued_jobs_inline

    chain.pipeline_records.each(&:reload)
    assert chain.pipeline_records.all?(&:terminal?), "Both upstreams should have completed"

    chain.then(ArchivePipeline, with: {})

    all_records = GoodPipeline::PipelineRecord.all.to_a
    run_all_to_completion(all_records)

    archive = all_records.find { |pipeline| pipeline.type == "ArchivePipeline" }

    assert_equal "succeeded", archive.status,
                 "Fan-in downstream registered after upstreams complete should still start"
  end

  private

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
end
