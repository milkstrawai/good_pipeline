# frozen_string_literal: true

require "test_helper"

class TestChainLocking < ActiveSupport::TestCase
  def test_fan_in_propagation_waits_for_downstream_lock_instead_of_dropping_wakeup # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    upstream_a = create_pipeline(type: "TestPipeline", status: "succeeded")
    upstream_b = create_pipeline(type: "TestPipeline", status: "succeeded")
    downstream = create_pipeline(type: "NotificationPipeline", status: "pending")
    root_step = build_step(downstream, key: "root")
    [upstream_a, upstream_b].each do |upstream|
      GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: downstream)
    end

    locked = Concurrent::CountDownLatch.new(1)
    release_lock = Concurrent::CountDownLatch.new(1)
    holder = hold_pipeline_lock(downstream.id, locked, release_lock)

    assert locked.wait(5), "downstream lock was not acquired"

    attempting_propagation = Concurrent::CountDownLatch.new(1)
    propagation = rails_promise do
      attempting_propagation.count_down
      GoodPipeline::ChainCoordinator.propagate_terminal_state(upstream_a)
    end

    begin
      assert attempting_propagation.wait(5), "propagation did not start"
      sleep 0.2

      assert_predicate propagation, :pending?, "propagation dropped the wake-up instead of waiting for the lock"
    ensure
      release_lock.count_down
    end

    holder.value!
    propagation.value!

    assert_equal "running", downstream.reload.status
    assert_equal "enqueued", root_step.reload.coordination_status
  end

  private

  def hold_pipeline_lock(pipeline_id, locked, release_lock)
    rails_promise do
      GoodPipeline::PipelineRecord.transaction do
        GoodPipeline::PipelineRecord.lock("FOR UPDATE").find(pipeline_id)
        locked.count_down
        release_lock.wait(5)
      end
    end
  end
end
