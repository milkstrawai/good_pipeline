# frozen_string_literal: true

require "test_helper"

# Barrier-driven coverage for chain propagation under concurrent settlement.
# These interleavings previously lost wakeups: with SKIP LOCKED, a propagation
# holding the downstream while reading a sibling upstream as still-running
# combined with that sibling skipping the held lock — both exited and the
# downstream stayed pending forever.
class TestConcurrentChainSettlement < ActiveSupport::TestCase
  ITERATIONS = 30

  def test_concurrent_fan_in_settlement_starts_downstream_exactly_once
    ITERATIONS.times do |iteration|
      upstream_a = drained_running_pipeline(key: "a")
      upstream_b = drained_running_pipeline(key: "b")
      downstream = create_pipeline(status: "pending")
      root = build_step(downstream, key: "root")
      GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream_a, downstream_pipeline: downstream)
      GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream_b, downstream_pipeline: downstream)

      latch = Concurrent::CountDownLatch.new(2)
      promises = [upstream_a, upstream_b].map do |upstream|
        rails_promise do
          latch.count_down
          latch.wait(5)
          GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
        end
      end
      promises.each(&:value!)

      assert_equal "running", downstream.reload.status,
                   "Iteration #{iteration}: downstream was stranded instead of started"
      assert_equal "enqueued", root.reload.coordination_status,
                   "Iteration #{iteration}: downstream root was not enqueued"
      # Counted in good_jobs, not on the step row: a duplicate start would
      # overwrite good_job_id and leave the step-row count at one.
      assert_equal 1, GoodJob::Job.where(job_class: "DownloadJob").count,
                   "Iteration #{iteration}: downstream root should be enqueued exactly once"

      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end
  end

  def test_chain_registration_racing_settlement_never_strands_the_downstream
    ITERATIONS.times do |iteration|
      upstream = drained_running_pipeline(key: "a")
      chain = GoodPipeline::Chain.new(upstream)

      latch = Concurrent::CountDownLatch.new(2)
      settle = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
      end
      register = rails_promise do
        latch.count_down
        latch.wait(5)
        chain.then(NotificationPipeline, with: {})
      end
      settle.value!
      register.value!

      downstream = GoodPipeline::PipelineRecord.where(type: "NotificationPipeline").sole

      refute_equal "pending", downstream.status,
                   "Iteration #{iteration}: downstream registered during settlement was stranded"

      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end
  end

  private

  # A running pipeline whose single step already succeeded: the next recompute
  # settles it as succeeded and propagates to its chained downstreams.
  def drained_running_pipeline(key:)
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: key).update_columns(coordination_status: "succeeded")
    pipeline
  end
end
