# frozen_string_literal: true

require_relative "../test_helper"

class TestChainPropagationJob < ActiveSupport::TestCase
  class QueuePipeline < GoodPipeline::Pipeline
    coordination_queue_name "edge_coordination"

    def configure(**) = run(:root, DownloadJob)
  end

  def test_terminal_transition_and_edge_job_commit_atomically
    upstream, downstream, edge = build_chain(upstream_status: "running")

    GoodPipeline::PipelineRecord.transaction do
      GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
    end

    assert_equal "succeeded", upstream.reload.status
    assert_equal "pending", downstream.reload.status
    assert_equal 1, propagation_jobs.where_job_arg(edge.id).count
  end

  def test_rollback_removes_terminal_transition_and_edge_job_together
    upstream, _downstream, edge = build_chain(upstream_status: "running")

    GoodPipeline::PipelineRecord.transaction do
      GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)

      assert_equal "succeeded", upstream.reload.status
      assert_equal 1, propagation_jobs.where_job_arg(edge.id).count
      raise ActiveRecord::Rollback
    end

    assert_equal "running", upstream.reload.status
    assert_equal 0, propagation_jobs.where_job_arg(edge.id).count
  end

  def test_rejected_chain_job_adapter_rolls_back_terminal_transition
    upstream, _downstream, edge = build_chain(upstream_status: "running")
    original_adapter = GoodPipeline::ChainPropagationJob.queue_adapter
    GoodPipeline::ChainPropagationJob.queue_adapter = ActiveJob::QueueAdapters::TestAdapter.new

    error = assert_raises(GoodPipeline::ConfigurationError) do
      GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
    end

    assert_match(/requires a GoodJob adapter/, error.message)
    assert_equal "running", upstream.reload.status
    assert_nil upstream.callbacks_dispatched_at
    assert_equal 0, propagation_jobs.where_job_arg(edge.id).count
  ensure
    GoodPipeline::ChainPropagationJob.queue_adapter = original_adapter if original_adapter
  end

  def test_deferred_chain_job_override_rolls_back_terminal_transition
    upstream, _downstream, edge = build_chain(upstream_status: "running")
    original_setting = GoodPipeline::ChainPropagationJob.enqueue_after_transaction_commit
    GoodPipeline::ChainPropagationJob.enqueue_after_transaction_commit = :always

    error = assert_raises(GoodPipeline::ConfigurationError) do
      GoodPipeline::Coordinator.recompute_pipeline_status(upstream.reload)
    end

    assert_match(/effectively defers enqueue/, error.message)
    assert_equal "running", upstream.reload.status
    assert_nil upstream.callbacks_dispatched_at
    assert_equal 0, propagation_jobs.where_job_arg(edge.id).count
  ensure
    GoodPipeline::ChainPropagationJob.enqueue_after_transaction_commit = original_setting
  end

  def test_durable_job_advances_downstream_later_without_direct_settlement_callback
    upstream, downstream, edge = build_chain(upstream_status: "succeeded")
    reserve(upstream)

    assert_equal "pending", downstream.reload.status
    assert_equal 1, propagation_jobs.where_job_arg(edge.id).count

    GoodPipeline::ChainPropagationJob.perform_now(edge.id)

    assert_equal "running", downstream.reload.status
    assert_equal "enqueued", downstream.steps.find_by!(key: "root").coordination_status
  end

  def test_duplicate_delivery_starts_downstream_and_enqueues_root_once
    upstream, downstream, edge = build_chain(upstream_status: "succeeded")
    reserve(upstream)

    2.times { GoodPipeline::ChainPropagationJob.perform_now(edge.id) }

    assert_equal "running", downstream.reload.status
    assert_equal 1, GoodJob::Job.where(job_class: "DownloadJob").count
  end

  def test_missing_edge_is_a_deliberate_noop
    assert_nothing_raised do
      GoodPipeline::ChainPropagationJob.perform_now(SecureRandom.uuid)
    end
  end

  def test_skipped_pipeline_reserves_its_own_outgoing_edge_before_commit
    upstream, middle, first_edge = build_chain(upstream_status: "failed")
    tail = pending_pipeline
    second_edge = GoodPipeline::ChainRecord.create!(upstream_pipeline: middle, downstream_pipeline: tail)
    reserve(upstream)

    GoodPipeline::ChainPropagationJob.perform_now(first_edge.id)

    assert_equal "skipped", middle.reload.status
    assert_equal "pending", tail.reload.status
    assert_equal 1, propagation_jobs.where_job_arg(second_edge.id).count

    GoodPipeline::ChainPropagationJob.perform_now(second_edge.id)
    assert_equal "skipped", tail.reload.status
  end

  def test_first_transient_failure_is_durably_retried
    upstream, downstream, edge = build_chain(upstream_status: "succeeded")
    reserve(upstream)
    attempts = 0
    original = GoodPipeline::ChainCoordinator.method(:propagate_edge)

    propagation = lambda do |edge_id|
      attempts += 1
      raise ActiveRecord::Deadlocked, "injected first-attempt failure" if attempts == 1

      original.call(edge_id)
    end

    with_stubbed_singleton_method(GoodPipeline::ChainCoordinator, :propagate_edge, propagation) do
      GoodJob.perform_inline
      assert_equal "pending", downstream.reload.status
      assert propagation_jobs.where(finished_at: nil).exists?, "retry was not durably scheduled"

      travel 1.minute do
        GoodJob.perform_inline
      end
    end

    assert_equal 2, attempts
    refute_equal "pending", downstream.reload.status
  end

  def test_one_transiently_failing_edge_does_not_block_an_unrelated_downstream
    upstream = create_pipeline(type: "TestPipeline", status: "succeeded", on_failure_strategy: "halt")
    blocked = pending_pipeline
    advancing = pending_pipeline
    blocked_edge = GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: blocked)
    advancing_edge = GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: advancing)
    reserve(upstream)

    original = GoodPipeline::ChainCoordinator.method(:propagate_edge)
    calls = Hash.new(0)
    propagation = lambda do |edge_id|
      calls[edge_id] += 1
      if edge_id == blocked_edge.id && calls[edge_id] == 1
        raise ActiveRecord::Deadlocked, "injected isolated failure"
      end

      original.call(edge_id)
    end

    with_stubbed_singleton_method(GoodPipeline::ChainCoordinator, :propagate_edge, propagation) do
      GoodJob.perform_inline
    end

    assert_equal "pending", blocked.reload.status
    refute_equal "pending", advancing.reload.status
    assert_equal 1, propagation_jobs.where_job_arg(blocked_edge.id).count
    assert_equal 1, propagation_jobs.where_job_arg(advancing_edge.id).count
  end

  def test_missing_pipeline_class_uses_global_coordination_queue
    upstream, _downstream, edge = build_chain(upstream_status: "succeeded", upstream_type: "RemovedPipeline")
    GoodPipeline.coordination_queue_name = "global_coordination"

    reserve(upstream)

    assert_equal "global_coordination", propagation_jobs.where_job_arg(edge.id).sole.queue_name
  ensure
    GoodPipeline.coordination_queue_name = nil
  end

  def test_propagation_uses_upstream_pipeline_coordination_queue
    upstream, _downstream, edge = build_chain(
      upstream_status: "succeeded",
      upstream_type: QueuePipeline.name
    )

    reserve(upstream)

    assert_equal "edge_coordination", propagation_jobs.where_job_arg(edge.id).sole.queue_name
  end

  def test_already_terminal_registration_commits_edge_and_durable_job_together
    upstream = create_pipeline(type: "TestPipeline", status: "succeeded", on_failure_strategy: "halt")

    downstream_chain = GoodPipeline::Chain.new(upstream).then(NotificationPipeline, with: {})
    downstream = downstream_chain.reload
    edge = GoodPipeline::ChainRecord.find_by!(upstream_pipeline: upstream, downstream_pipeline: downstream)

    assert_equal "pending", downstream.status
    assert_equal 1, propagation_jobs.where_job_arg(edge.id).count
  end

  def test_registration_rolls_back_graph_and_edges_when_durable_reservation_fails
    upstream = create_pipeline(type: "TestPipeline", status: "succeeded", on_failure_strategy: "halt")
    pipeline_count = GoodPipeline::PipelineRecord.count
    batch_count = GoodJob::BatchRecord.count

    error = assert_raises(ActiveJob::EnqueueError) do
      with_stubbed_singleton_method(
        GoodPipeline::ChainCoordinator,
        :reserve_terminal_state!,
        ->(*, **) { raise ActiveJob::EnqueueError, "injected reservation failure" }
      ) do
        GoodPipeline::Chain.new(upstream).then(NotificationPipeline, with: {})
      end
    end

    assert_equal "injected reservation failure", error.message
    assert_equal pipeline_count, GoodPipeline::PipelineRecord.count
    assert_equal batch_count, GoodJob::BatchRecord.count
    assert_equal 0, GoodPipeline::ChainRecord.count
  end

  private

  def build_chain(upstream_status:, upstream_type: "TestPipeline")
    upstream = create_pipeline(type: upstream_type, status: upstream_status, on_failure_strategy: "halt")
    downstream = pending_pipeline
    edge = GoodPipeline::ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: downstream)
    [upstream, downstream, edge]
  end

  def pending_pipeline
    create_pipeline(type: "TestPipeline", status: "pending", on_failure_strategy: "halt").tap do |pipeline|
      build_step(pipeline, key: "root")
    end
  end

  def reserve(upstream)
    GoodPipeline::PipelineRecord.transaction do
      locked = GoodPipeline::PipelineRecord.lock("FOR UPDATE").find(upstream.id)
      GoodPipeline::ChainCoordinator.reserve_terminal_state!(locked)
    end
  end

  def propagation_jobs
    GoodJob::Job.where(job_class: "GoodPipeline::ChainPropagationJob").extending(JobArgumentScope)
  end

  module JobArgumentScope
    def where_job_arg(argument)
      where("serialized_params -> 'arguments' @> ?::jsonb", [argument].to_json)
    end
  end
end
