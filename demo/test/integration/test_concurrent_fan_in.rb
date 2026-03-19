# frozen_string_literal: true

require "test_helper"

class TestConcurrentFanIn < ActiveSupport::TestCase
  def test_simultaneous_upstream_completion_enqueues_downstream_exactly_once
    50.times do |iteration|
      pipeline = create_pipeline(on_failure_strategy: "halt")
      pipeline.update_columns(status: "running")
      step_a = build_step(pipeline, key: "a")
      step_b = build_step(pipeline, key: "b")
      step_c = build_step(pipeline, key: "c", dependencies: [step_a, step_b])
      step_a.update_columns(coordination_status: "enqueued")
      step_b.update_columns(coordination_status: "enqueued")

      latch = Concurrent::CountDownLatch.new(2)

      promise_a = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.complete_step(step_a.reload, succeeded: true)
      end

      promise_b = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.complete_step(step_b.reload, succeeded: true)
      end

      promise_a.value!
      promise_b.value!

      step_c.reload

      refute_equal "pending", step_c.coordination_status,
                   "Iteration #{iteration}: step_c should not still be pending"

      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end
  end

  def test_triple_fan_in_enqueues_downstream_exactly_once
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b")
    step_c = build_step(pipeline, key: "c")
    step_d = build_step(pipeline, key: "d", dependencies: [step_a, step_b, step_c])
    [step_a, step_b, step_c].each { |step| step.update_columns(coordination_status: "enqueued") }

    latch = Concurrent::CountDownLatch.new(3)

    promises = [step_a, step_b, step_c].map do |step|
      rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.complete_step(step.reload, succeeded: true)
      end
    end

    promises.each(&:value!)

    step_d.reload

    refute_equal "pending", step_d.coordination_status
  end

  def test_good_job_id_guard_prevents_double_enqueue
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")
    fake_job_id = SecureRandom.uuid
    step.update_column(:good_job_id, fake_job_id)

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    assert_equal "pending", step.coordination_status
    assert_equal fake_job_id, step.good_job_id
  end

  def test_coordinator_interleave_enqueues_only_once
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")

    latch = Concurrent::CountDownLatch.new(2)

    promise_1 = rails_promise do
      latch.count_down
      latch.wait(5)
      GoodPipeline::Coordinator.try_enqueue_step(step.id)
    end

    promise_2 = rails_promise do
      latch.count_down
      latch.wait(5)
      GoodPipeline::Coordinator.try_enqueue_step(step.id)
    end

    promise_1.value!
    promise_2.value!

    step.reload

    refute_equal "pending", step.coordination_status
  end
end
