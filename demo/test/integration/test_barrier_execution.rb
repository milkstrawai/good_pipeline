# frozen_string_literal: true

require "test_helper"

BarrierExecutionPipeline = Class.new(GoodPipeline::Pipeline) do
  def configure(**)
    run :fetch_a, DownloadJob
    run :fetch_b, DownloadJob
    barrier
    run :publish_a, PublishJob
    run :publish_b, PublishJob
  end
end

MultipleBarrierExecutionPipeline = Class.new(GoodPipeline::Pipeline) do
  def configure(**)
    run :fetch, DownloadJob
    barrier
    run :transform, TranscodeJob
    barrier
    run :publish, PublishJob
  end
end

BranchThenBarrierExecutionPipeline = Class.new(GoodPipeline::Pipeline) do
  def configure(**)
    branch :route, by: :pick do
      on(:work) { run :work, DownloadJob }
      on :skip
    end
    barrier
    run :publish, PublishJob
  end

  private

  def pick = params[:choice].to_sym
end

AllEmptyBranchThenBarrierPipeline = Class.new(GoodPipeline::Pipeline) do
  def configure(**)
    branch :route, by: :pick do
      on :skip
      on :archive
    end
    barrier
    run :publish, PublishJob
  end

  private

  def pick = params[:choice].to_sym
end

BarrierThenBranchExecutionPipeline = Class.new(GoodPipeline::Pipeline) do
  def configure(**)
    run :fetch, DownloadJob
    barrier
    branch :route, by: :pick do
      on(:work) { run :work, TranscodeJob }
      on :skip
    end
    run :publish, PublishJob, after: :route
  end

  private

  def pick = params[:choice].to_sym
end

AllEmptyBranchAfterBarrierExecutionPipeline = Class.new(GoodPipeline::Pipeline) do
  def configure(**)
    run :fetch, DownloadJob
    barrier
    branch :route, by: :pick do
      on :skip
      on :archive
    end
    run :publish, PublishJob, after: :route
  end

  private

  def pick = params[:choice].to_sym
end

BranchExternalDependencyExecutionPipeline = Class.new(GoodPipeline::Pipeline) do
  failure_strategy :continue

  def configure(**)
    run :shared, DownloadJob
    branch :route, by: :pick do
      on(:chosen) { run :chosen, DownloadJob }
      on(:unused) { run :unused, DownloadJob, after: :shared }
    end
    run :finish, DownloadJob, after: :route
  end

  private

  def pick = :chosen
end

BranchExternalDependencyBarrierPipeline = Class.new(GoodPipeline::Pipeline) do
  failure_strategy :continue

  def configure(**)
    run :shared, DownloadJob
    branch :route, by: :pick do
      on(:chosen) { run :chosen, DownloadJob }
      on(:unused) { run :unused, DownloadJob, after: :shared }
    end
    barrier
    run :finish, DownloadJob
  end

  private

  def pick = :chosen
end

# Integration assertions intentionally keep each coordination scenario together.
# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength
class TestBarrierExecution < ActiveSupport::TestCase
  def test_full_pipeline_crosses_barrier_without_enqueuing_it
    pipeline = run_pipeline_to_completion(BarrierExecutionPipeline.run)
    barrier = pipeline.steps.find_by!(job_class: GoodPipeline::BARRIER_JOB_CLASS)

    assert_equal "succeeded", pipeline.status
    assert_equal "succeeded", barrier.coordination_status
    assert_nil barrier.good_job_id
    assert_nil barrier.good_job_batch_id
    assert pipeline.steps.where.not(job_class: GoodPipeline::BARRIER_JOB_CLASS).all?(&:succeeded?)
  end

  def test_full_pipeline_crosses_multiple_barriers
    pipeline = run_pipeline_to_completion(MultipleBarrierExecutionPipeline.run)
    barriers = pipeline.steps.where(job_class: GoodPipeline::BARRIER_JOB_CLASS).order(:key)

    assert_equal "succeeded", pipeline.status
    assert_equal 2, barriers.count
    assert barriers.all?(&:succeeded?)
    assert(barriers.all? { |step| step.good_job_id.nil? })
  end

  def test_barrier_after_branch_resolves_for_selected_and_empty_arms
    %w[work skip].each do |choice|
      pipeline = run_pipeline_to_completion(BranchThenBarrierExecutionPipeline.run(choice: choice))
      steps = pipeline.steps.index_by(&:key)

      assert_equal "succeeded", pipeline.status
      assert_equal "succeeded", steps.fetch("__good_pipeline_barrier_1").coordination_status
      assert_equal "succeeded", steps.fetch("publish").coordination_status
    end
  end

  def test_barrier_after_all_empty_branch_resolves_from_sentinel
    pipeline = run_pipeline_to_completion(AllEmptyBranchThenBarrierPipeline.run(choice: "skip"))
    steps = pipeline.steps.index_by(&:key)

    assert_equal "succeeded", pipeline.status
    assert_equal "skip", steps.fetch("route").branch_result
    assert_equal "succeeded", steps.fetch("__good_pipeline_barrier_1").coordination_status
    assert_equal "succeeded", steps.fetch("publish").coordination_status
  end

  def test_barrier_before_branch_gates_the_decision_for_selected_and_empty_arms
    %w[work skip].each do |choice|
      pipeline = run_pipeline_to_completion(BarrierThenBranchExecutionPipeline.run(choice: choice))
      steps = pipeline.steps.index_by(&:key)

      assert_equal "succeeded", pipeline.status
      assert_equal "succeeded", steps.fetch("__good_pipeline_barrier_1").coordination_status
      assert_equal choice, steps.fetch("route").branch_result
      assert_equal "succeeded", steps.fetch("publish").coordination_status
    end
  end

  def test_barrier_before_all_empty_branch_preserves_runtime_order
    %w[skip archive].each do |choice|
      pipeline = run_pipeline_to_completion(AllEmptyBranchAfterBarrierExecutionPipeline.run(choice: choice))
      steps = pipeline.steps.index_by(&:key)

      assert_equal "succeeded", pipeline.status
      assert_equal "succeeded", steps.fetch("__good_pipeline_barrier_1").coordination_status
      assert_equal choice, steps.fetch("route").branch_result
      assert_equal "succeeded", steps.fetch("publish").coordination_status
    end
  end

  def test_nonselected_arm_is_pruned_when_branch_resolves_before_external_failure
    pipeline, steps = build_stopped_pipeline(BranchExternalDependencyExecutionPipeline)

    GoodPipeline::Coordinator.bulk_enqueue_steps([steps.fetch("route").id])

    assert_equal "skipped_by_branch", steps.fetch("unused").reload.coordination_status
    assert_equal "enqueued", steps.fetch("chosen").reload.coordination_status

    fail_shared_step(steps)
    complete_selected_branch(steps)

    assert_equal "skipped_by_branch", steps.fetch("unused").reload.coordination_status
    assert_equal "enqueued", steps.fetch("finish").reload.coordination_status

    GoodPipeline::Coordinator.complete_step(steps.fetch("finish").id, succeeded: true)

    assert_equal "failed", pipeline.reload.status
  end

  def test_nonselected_arm_precedes_dependency_failure_when_external_failure_finishes_first
    pipeline, steps = build_stopped_pipeline(BranchExternalDependencyExecutionPipeline)

    fail_shared_step(steps)

    assert_equal "pending", steps.fetch("unused").reload.coordination_status

    GoodPipeline::Coordinator.bulk_enqueue_steps([steps.fetch("route").id])

    assert_equal "skipped_by_branch", steps.fetch("unused").reload.coordination_status
    complete_selected_branch(steps)

    assert_equal "enqueued", steps.fetch("finish").reload.coordination_status

    GoodPipeline::Coordinator.complete_step(steps.fetch("finish").id, succeeded: true)

    assert_equal "failed", pipeline.reload.status
  end

  def test_barrier_waits_for_external_phase_work_after_unused_arm_is_pruned
    pipeline, steps = build_stopped_pipeline(BranchExternalDependencyBarrierPipeline)
    shared = steps.fetch("shared")
    barrier = steps.fetch("__good_pipeline_barrier_1")
    shared.update_columns(coordination_status: "enqueued")

    GoodPipeline::Coordinator.bulk_enqueue_steps([steps.fetch("route").id])
    GoodPipeline::Coordinator.complete_step(steps.fetch("chosen").id, succeeded: true)

    assert_equal "skipped_by_branch", steps.fetch("unused").reload.coordination_status
    assert_equal "pending", barrier.reload.coordination_status
    assert_equal 1, barrier.pending_upstream_count
    assert_equal "pending", steps.fetch("finish").reload.coordination_status

    GoodPipeline::Coordinator.complete_step(shared.id, succeeded: true)

    assert_equal "succeeded", barrier.reload.coordination_status
    assert_equal "enqueued", steps.fetch("finish").reload.coordination_status

    GoodPipeline::Coordinator.complete_step(steps.fetch("finish").id, succeeded: true)

    assert_equal "succeeded", pipeline.reload.status
  end

  def test_failed_phase_step_does_not_skip_barrier_before_selected_arm_finishes
    pipeline, steps = build_stopped_pipeline(BranchExternalDependencyBarrierPipeline)
    barrier = steps.fetch("__good_pipeline_barrier_1")

    fail_shared_step(steps)
    GoodPipeline::Coordinator.bulk_enqueue_steps([steps.fetch("route").id])

    assert_equal "skipped_by_branch", steps.fetch("unused").reload.coordination_status
    assert_equal "enqueued", steps.fetch("chosen").reload.coordination_status
    assert_equal "pending", barrier.reload.coordination_status
    assert_equal 1, barrier.pending_upstream_count
    assert_equal "pending", steps.fetch("finish").reload.coordination_status

    GoodPipeline::Coordinator.complete_step(steps.fetch("chosen").id, succeeded: true)

    assert_equal "skipped", barrier.reload.coordination_status
    assert_equal "skipped", steps.fetch("finish").reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  def test_barrier_waits_for_last_upstream_and_redelivery_does_not_double_release
    pipeline, step_a, step_b, barrier, publish = build_manual_barrier_pipeline(strategy: "continue")

    GoodPipeline::Coordinator.complete_step(step_a.id, succeeded: true)

    assert_equal "pending", barrier.reload.coordination_status
    assert_equal 1, barrier.pending_upstream_count
    assert_equal "pending", publish.reload.coordination_status

    GoodPipeline::Coordinator.complete_step(step_a.id, succeeded: true)

    assert_equal 1, barrier.reload.pending_upstream_count

    GoodPipeline::Coordinator.complete_step(step_b.id, succeeded: true)

    assert_equal "succeeded", barrier.reload.coordination_status
    assert_equal 0, barrier.pending_upstream_count
    assert_equal "enqueued", publish.reload.coordination_status
    refute_nil publish.good_job_id
    assert_equal "running", pipeline.reload.status
  end

  def test_concurrent_upstream_completions_release_barrier_once
    _pipeline, step_a, step_b, barrier, publish = build_manual_barrier_pipeline(strategy: "continue")
    latch = Concurrent::CountDownLatch.new(2)

    promises = [step_a, step_b].map do |step|
      rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.complete_step(step.id, succeeded: true)
      end
    end
    promises.each(&:value!)

    assert_equal "succeeded", barrier.reload.coordination_status
    assert_equal 0, barrier.pending_upstream_count
    assert_equal "enqueued", publish.reload.coordination_status
    refute_nil publish.good_job_id
  end

  def test_skipped_step_remains_blocking_under_inherited_ignore
    pipeline = create_pipeline(status: "running", on_failure_strategy: "ignore")
    failed = build_step(pipeline, key: "failed", on_failure_strategy: "continue")
    skipped = build_step(pipeline, key: "skipped", dependencies: [failed])
    descendant = build_step(pipeline, key: "descendant", dependencies: [skipped])
    failed.update_columns(coordination_status: "enqueued")

    GoodPipeline::Coordinator.complete_step(failed.id, succeeded: false)

    assert_equal "failed", failed.reload.coordination_status
    assert_equal "skipped", skipped.reload.coordination_status
    assert_equal "skipped", descendant.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  def test_partial_halt_skip_releases_phase_step_to_barrier
    pipeline = create_pipeline(status: "running", on_failure_strategy: "halt")
    optional = build_step(pipeline, key: "optional", on_failure_strategy: "ignore")
    prepare = build_step(pipeline, key: "prepare")
    finalize = build_step(pipeline, key: "finalize", dependencies: [prepare])
    barrier = build_step(
      pipeline,
      key: "barrier",
      job_class: GoodPipeline::BARRIER_JOB_CLASS,
      dependencies: [optional, prepare, finalize]
    )
    publish = build_step(pipeline, key: "publish", dependencies: [barrier])
    optional.update_columns(coordination_status: "enqueued")
    prepare.update_columns(coordination_status: "enqueued")

    GoodPipeline::Coordinator.complete_step(optional.id, succeeded: false)

    assert_equal "skipped", finalize.reload.coordination_status
    assert_equal "pending", barrier.reload.coordination_status
    assert_equal 1, barrier.pending_upstream_count
    assert_equal "pending", publish.reload.coordination_status

    GoodPipeline::Coordinator.complete_step(prepare.id, succeeded: true)

    assert_equal "skipped", barrier.reload.coordination_status
    assert_equal 0, barrier.pending_upstream_count
    assert_equal "skipped", publish.reload.coordination_status
    assert_equal "halted", pipeline.reload.status
  end

  def test_bulk_configuration_failure_before_barrier_under_continue
    pipeline, failure, barrier, publish = build_configuration_failure_pipeline(strategy: "continue")

    GoodPipeline::Coordinator.bulk_enqueue_steps([failure.id])

    assert_equal "failed", failure.reload.coordination_status
    assert_equal "skipped", barrier.reload.coordination_status
    assert_equal 0, barrier.pending_upstream_count
    assert_equal "skipped", publish.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  def test_bulk_configuration_failure_before_barrier_under_ignore
    pipeline, failure, barrier, publish = build_configuration_failure_pipeline(strategy: "ignore")

    GoodPipeline::Coordinator.bulk_enqueue_steps([failure.id])

    assert_equal "failed", failure.reload.coordination_status
    assert_equal "succeeded", barrier.reload.coordination_status
    assert_equal 0, barrier.pending_upstream_count
    assert_equal "enqueued", publish.reload.coordination_status

    GoodPipeline::Coordinator.complete_step(publish.id, succeeded: true)

    assert_equal "failed", pipeline.reload.status
  end

  def test_two_bulk_configuration_failures_release_shared_barrier_twice
    pipeline = create_pipeline(status: "running", on_failure_strategy: "ignore")
    failure_a = build_step(pipeline, key: "failure_a", job_class: "MissingBarrierJobA")
    failure_b = build_step(pipeline, key: "failure_b", job_class: "MissingBarrierJobB")
    barrier = build_step(
      pipeline,
      key: "barrier",
      job_class: GoodPipeline::BARRIER_JOB_CLASS,
      dependencies: [failure_a, failure_b]
    )
    publish = build_step(pipeline, key: "publish", dependencies: [barrier])

    GoodPipeline::Coordinator.bulk_enqueue_steps([failure_a.id, failure_b.id])

    assert_equal %w[failed failed], [failure_a.reload.coordination_status, failure_b.reload.coordination_status]
    assert_equal "succeeded", barrier.reload.coordination_status
    assert_equal 0, barrier.pending_upstream_count
    assert_equal "enqueued", publish.reload.coordination_status
  end

  def test_bulk_ignored_failures_protect_union_of_halt_subtrees
    pipeline = create_pipeline(status: "running", on_failure_strategy: "halt")
    failure_a = build_step(
      pipeline, key: "failure_a", job_class: "MissingIgnoredBarrierJobA", on_failure_strategy: "ignore"
    )
    failure_b = build_step(
      pipeline, key: "failure_b", job_class: "MissingIgnoredBarrierJobB", on_failure_strategy: "ignore"
    )
    exit_a = build_step(pipeline, key: "exit_a", dependencies: [failure_a])
    exit_b = build_step(pipeline, key: "exit_b", dependencies: [failure_b])
    barrier = build_step(
      pipeline,
      key: "barrier",
      job_class: GoodPipeline::BARRIER_JOB_CLASS,
      dependencies: [failure_a, failure_b, exit_a, exit_b]
    )
    publish = build_step(pipeline, key: "publish", dependencies: [barrier])

    GoodPipeline::Coordinator.bulk_enqueue_steps([failure_a.id, failure_b.id])

    assert_equal %w[failed failed], [failure_a.reload.coordination_status, failure_b.reload.coordination_status]
    assert_equal %w[enqueued enqueued], [exit_a.reload.coordination_status, exit_b.reload.coordination_status]
    assert_equal "pending", barrier.reload.coordination_status

    GoodPipeline::Coordinator.complete_step(exit_a.id, succeeded: true)
    GoodPipeline::Coordinator.complete_step(exit_b.id, succeeded: true)

    assert_equal "succeeded", barrier.reload.coordination_status
    assert_equal "enqueued", publish.reload.coordination_status

    GoodPipeline::Coordinator.complete_step(publish.id, succeeded: true)

    assert_equal "halted", pipeline.reload.status
  end

  def test_cancellation_cancels_pending_barrier_and_never_enqueues_later_phase
    pipeline, step_a, _step_b, barrier, publish = build_manual_barrier_pipeline(strategy: "continue")

    GoodPipeline::Coordinator.cancel_pipeline(pipeline.id)

    assert_equal "canceled", barrier.reload.coordination_status
    assert_equal "canceled", publish.reload.coordination_status
    assert_nil publish.good_job_id

    GoodPipeline::Coordinator.complete_step(step_a.id, succeeded: true)

    assert_nil publish.reload.good_job_id
  end

  private

  def build_stopped_pipeline(pipeline_class)
    pipeline = GoodPipeline::Runner.call(pipeline_class.build, start: false)
    pipeline.transition_to!(:running)
    [pipeline, pipeline.steps.index_by(&:key)]
  end

  def fail_shared_step(steps)
    shared = steps.fetch("shared")
    shared.update_columns(coordination_status: "enqueued")
    GoodPipeline::Coordinator.complete_step(shared.id, succeeded: false)
  end

  def complete_selected_branch(steps)
    GoodPipeline::Coordinator.complete_step(steps.fetch("chosen").id, succeeded: true)
  end

  def build_manual_barrier_pipeline(strategy:)
    pipeline = create_pipeline(status: "running", on_failure_strategy: strategy)
    step_a = build_step(pipeline, key: "a")
    step_b = build_step(pipeline, key: "b")
    barrier = build_step(
      pipeline,
      key: "barrier",
      job_class: GoodPipeline::BARRIER_JOB_CLASS,
      dependencies: [step_a, step_b]
    )
    publish = build_step(pipeline, key: "publish", dependencies: [barrier])
    step_a.update_columns(coordination_status: "enqueued")
    step_b.update_columns(coordination_status: "enqueued")
    [pipeline, step_a, step_b, barrier, publish]
  end

  def build_configuration_failure_pipeline(strategy:)
    pipeline = create_pipeline(status: "running", on_failure_strategy: strategy)
    failure = build_step(pipeline, key: "failure", job_class: "MissingBarrierJob")
    barrier = build_step(
      pipeline,
      key: "barrier",
      job_class: GoodPipeline::BARRIER_JOB_CLASS,
      dependencies: [failure]
    )
    publish = build_step(pipeline, key: "publish", dependencies: [barrier])
    [pipeline, failure, barrier, publish]
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/MethodLength
