# frozen_string_literal: true

require "test_helper"

# Barrier-driven coverage for durable chain propagation and its registration
# handshake. Terminal settlement reserves one GoodJob row per edge; duplicate
# deliveries then serialize on the pending downstream row. Registration and
# settlement take the same upstream lock, so either actor reliably observes the
# state committed by the other.
class TestConcurrentChainSettlement < ActiveSupport::TestCase
  ITERATIONS = 30

  def test_concurrent_fan_in_settlement_starts_downstream_exactly_once
    ITERATIONS.times do |iteration|
      upstream_a = drained_running_pipeline(key: "a")
      upstream_b = drained_running_pipeline(key: "b")
      downstream = create_pipeline(status: "pending")
      root = build_step(downstream, key: "root")
      edges = [upstream_a, upstream_b].map do |upstream|
        GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: downstream)
      end

      latch = Concurrent::CountDownLatch.new(2)
      promises = [upstream_a, upstream_b].map do |upstream|
        rails_promise do
          latch.count_down
          latch.wait(5)
          GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
        end
      end
      promises.each(&:value!)

      assert_equal "pending", downstream.reload.status,
                   "Iteration #{iteration}: durable handoff should not require in-process propagation"
      assert_equal 2, propagation_jobs_for(edges).count,
                   "Iteration #{iteration}: each committed edge needs its own durable job"

      delivery_latch = Concurrent::CountDownLatch.new(2)
      deliveries = edges.map do |edge|
        rails_promise do
          delivery_latch.count_down
          delivery_latch.wait(5)
          GoodPipeline::ChainPropagationJob.perform_now(edge.id)
        end
      end
      deliveries.each(&:value!)

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

  def test_concurrent_fan_in_with_one_failure_skips_downstream_exactly_once
    ITERATIONS.times do |iteration|
      upstream_a = drained_running_pipeline(key: "a")
      upstream_b = drained_failed_pipeline(key: "b")
      downstream = create_pipeline(status: "pending")
      root = build_step(downstream, key: "root")
      edges = [upstream_a, upstream_b].map do |upstream|
        GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: downstream)
      end

      settlement_latch = Concurrent::CountDownLatch.new(2)
      settlements = [upstream_a, upstream_b].map do |upstream|
        rails_promise do
          settlement_latch.count_down
          settlement_latch.wait(5)
          GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
        end
      end
      settlements.each(&:value!)

      assert_equal 2, propagation_jobs_for(edges).count,
                   "Iteration #{iteration}: each terminal prerequisite needs a durable edge job"

      delivery_latch = Concurrent::CountDownLatch.new(2)
      deliveries = edges.map do |edge|
        rails_promise do
          delivery_latch.count_down
          delivery_latch.wait(5)
          GoodPipeline::ChainPropagationJob.perform_now(edge.id)
        end
      end
      deliveries.each(&:value!)

      assert_equal "skipped", downstream.reload.status,
                   "Iteration #{iteration}: a failed prerequisite did not skip the downstream"
      assert_equal "pending", root.reload.coordination_status,
                   "Iteration #{iteration}: a skipped downstream unexpectedly started its root"
      assert_equal 0, GoodJob::Job.where(job_class: "DownloadJob").count,
                   "Iteration #{iteration}: skipped downstream root was enqueued"
      assert_equal 1, callback_jobs_for(downstream).count,
                   "Iteration #{iteration}: duplicate propagation dispatched callbacks more than once"

      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end
  end

  def test_registration_holds_upstream_lock_until_new_edge_is_committed
    upstream = drained_running_pipeline(key: "a")
    chain = GoodPipeline::Chain.new(upstream)
    edge_created = Concurrent::CountDownLatch.new(1)
    release_registration = Concurrent::CountDownLatch.new(1)
    original = chain.method(:create_incoming_edges)

    registration = nil
    with_stubbed_singleton_method(chain, :create_incoming_edges, lambda { |upstreams, downstreams|
      result = original.call(upstreams, downstreams)
      edge_created.count_down
      release_registration.wait(10)
      result
    }) do
      registration = rails_promise { chain.then(NotificationPipeline, with: {}) }
      assert edge_created.wait(10), "registration never created its edge while holding the upstream lock"

      settlement = rails_promise do
        GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
      end

      # Registration commits first. Settlement can only acquire the upstream
      # row afterwards, so its edge query must include the new relationship.
      release_registration.count_down
      registration.value!(10)
      settlement.value!(10)
    end

    downstream = GoodPipeline::PipelineRecord.where(type: "NotificationPipeline").sole
    edge = GoodPipeline::ChainRecord.find_by!(upstream_pipeline: upstream, downstream_pipeline: downstream)

    assert_equal 1, propagation_jobs_for([edge]).count
    GoodPipeline::ChainPropagationJob.perform_now(edge.id)
    refute_equal "pending", downstream.reload.status
  end

  def test_settlement_holds_upstream_lock_until_terminal_job_is_committed
    upstream = drained_running_pipeline(key: "a")
    chain = GoodPipeline::Chain.new(upstream)
    settlement_locked = Concurrent::CountDownLatch.new(1)
    registration_started = Concurrent::CountDownLatch.new(1)
    release_settlement = Concurrent::CountDownLatch.new(1)
    original = GoodPipeline::ChainCoordinator.method(:reserve_terminal_state!)

    reservation = lambda do |locked_pipeline, chain_ids: nil|
      if locked_pipeline.id == upstream.id && chain_ids.nil?
        settlement_locked.count_down
        registration_started.wait(10)
        release_settlement.wait(10)
      end
      original.call(locked_pipeline, chain_ids: chain_ids)
    end

    with_stubbed_singleton_method(GoodPipeline::ChainCoordinator, :reserve_terminal_state!, reservation) do
      settlement = rails_promise do
        GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
      end

      assert settlement_locked.wait(10), "settlement never reached durable reservation under its upstream lock"
      registration = rails_promise do
        registration_started.count_down
        chain.then(NotificationPipeline, with: {})
      end

      # Settlement commits first with no visible edge. Registration then
      # acquires the same row, reloads terminal state, and reserves the edge.
      release_settlement.count_down
      settlement.value!(10)
      registration.value!(10)
    end

    downstream = GoodPipeline::PipelineRecord.where(type: "NotificationPipeline").sole
    edge = GoodPipeline::ChainRecord.find_by!(upstream_pipeline: upstream, downstream_pipeline: downstream)

    assert_equal 1, propagation_jobs_for([edge]).count
    GoodPipeline::ChainPropagationJob.perform_now(edge.id)
    refute_equal "pending", downstream.reload.status
  end

  def test_multi_upstream_registrations_lock_in_primary_key_order
    upstream_a = drained_running_pipeline(key: "a")
    upstream_b = drained_running_pipeline(key: "b")
    first_chain = GoodPipeline::Chain.new([upstream_a, upstream_b])
    second_chain = GoodPipeline::Chain.new([upstream_b, upstream_a])
    barrier = Concurrent::CountDownLatch.new(2)

    first_lock = first_chain.method(:lock_upstreams!)
    second_lock = second_chain.method(:lock_upstreams!)
    synchronized_first_lock = lambda do
      barrier.count_down
      barrier.wait(10)
      first_lock.call
    end
    synchronized_second_lock = lambda do
      barrier.count_down
      barrier.wait(10)
      second_lock.call
    end

    with_stubbed_singleton_method(first_chain, :lock_upstreams!, synchronized_first_lock) do
      with_stubbed_singleton_method(second_chain, :lock_upstreams!, synchronized_second_lock) do
        registrations = [first_chain, second_chain].map do |pipeline_chain|
          rails_promise { pipeline_chain.then(NotificationPipeline, with: {}) }
        end
        registrations.each { |registration| registration.value!(10) }
      end
    end

    downstreams = GoodPipeline::PipelineRecord.where(type: "NotificationPipeline")

    assert_equal 2, downstreams.count
    assert_equal 4, GoodPipeline::ChainRecord.where(downstream_pipeline_id: downstreams.select(:id)).count
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

  def drained_failed_pipeline(key:)
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: key).update_columns(coordination_status: "failed")
    pipeline
  end

  def propagation_jobs_for(edges)
    ids = edges.map { |edge| edge.id.to_s }
    GoodJob::Job.where(job_class: "GoodPipeline::ChainPropagationJob").select do |job|
      ids.include?(job.serialized_params.fetch("arguments").first.to_s)
    end
  end

  def callback_jobs_for(pipeline)
    GoodJob::Job.where(job_class: "GoodPipeline::PipelineCallbackJob").select do |job|
      job.serialized_params.fetch("arguments").first.to_s == pipeline.id.to_s
    end
  end
end
