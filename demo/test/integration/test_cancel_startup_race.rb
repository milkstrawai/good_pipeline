# frozen_string_literal: true

require "test_helper"

# Runner commits the pipeline before enqueueing its roots, so a cancel can
# arrive in that window, skip the pending roots and settle the pipeline —
# previously the bulk path then stamped the skipped steps back to `enqueued`
# with live jobs on a terminal record. Separately, an in-flight
# try_enqueue_step holding an uncommitted step lock was invisible to bulk's
# unlocked re-select, double-enqueueing the same root.
class TestCancelStartupRace < ActiveSupport::TestCase
  RACE_ITERATIONS = 30
  EXACTLY_ONCE_ITERATIONS = 20

  def test_root_enqueue_after_a_completed_cancel_is_a_no_op
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    roots = [build_step(pipeline, key: "a"), build_step(pipeline, key: "b")]

    assert GoodPipeline::Coordinator.cancel_pipeline(pipeline)
    assert_equal "halted", pipeline.reload.status

    GoodPipeline::Coordinator.bulk_enqueue_steps(roots.map(&:id))

    roots.each { |step| assert_equal "skipped", step.reload.coordination_status }
    assert_equal 0, user_job_count
    assert_equal 0, step_batch_count(roots)
    assert_equal "halted", pipeline.reload.status
  end

  def test_bulk_racing_try_enqueue_creates_exactly_one_job_per_root
    EXACTLY_ONCE_ITERATIONS.times do |iteration|
      pipeline = create_pipeline(on_failure_strategy: "halt")
      pipeline.update_columns(status: "running")
      root = build_step(pipeline, key: "a")

      latch = Concurrent::CountDownLatch.new(2)
      bulk = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.bulk_enqueue_steps([root.id])
      end
      single = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.try_enqueue_step(root.id)
      end
      bulk.value!
      single.value!

      root.reload

      assert_equal "enqueued", root.coordination_status, "Iteration #{iteration}"
      assert_equal 1, user_job_count, "Iteration #{iteration}: root enqueued more than once"
      assert_equal 1, step_batch_count([root]), "Iteration #{iteration}: more than one step batch"
      assert_equal GoodJob::Job.sole.id, root.good_job_id,
                   "Iteration #{iteration}: step must reference the single surviving job"

      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end
  end

  def test_bulk_enqueue_rejects_steps_spanning_pipelines
    pipeline_a = create_pipeline(on_failure_strategy: "halt")
    pipeline_b = create_pipeline(on_failure_strategy: "halt")
    step_a = build_step(pipeline_a, key: "a")
    step_b = build_step(pipeline_b, key: "a")

    assert_raises(ArgumentError) do
      GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])
    end
  end

  def test_cancel_racing_root_enqueue_never_resurrects_skipped_steps
    RACE_ITERATIONS.times do |iteration|
      pipeline = create_pipeline(on_failure_strategy: "halt")
      pipeline.update_columns(status: "running")
      roots = [build_step(pipeline, key: "a"), build_step(pipeline, key: "b")]

      latch = Concurrent::CountDownLatch.new(2)
      enqueue = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.bulk_enqueue_steps(roots.map(&:id))
      end
      cancel = rails_promise do
        latch.count_down
        latch.wait(5)
        GoodPipeline::Coordinator.cancel_pipeline(pipeline.reload)
      end
      enqueue.value!
      cancel.value!

      pipeline.reload
      statuses = roots.map { |step| step.reload.coordination_status }

      if pipeline.terminal?
        # Cancel won before any root was enqueued: nothing may be resurrected
        # behind the settlement. (Assertions are scoped to the roots — a
        # canceled pipeline that had running work legitimately retains
        # preserved job rows in general.)
        assert_equal %w[skipped skipped], statuses,
                     "Iteration #{iteration}: terminal pipeline has non-skipped roots #{statuses.inspect}"
        assert_equal 0, user_job_count, "Iteration #{iteration}: terminal pipeline has root jobs"
        assert_equal 0, step_batch_count(roots), "Iteration #{iteration}: terminal pipeline has root batches"
        assert_equal "halted", pipeline.status
      else
        # Enqueue won: the cancel is draining the in-flight roots normally.
        assert_equal %w[enqueued enqueued], statuses,
                     "Iteration #{iteration}: running pipeline has unenqueued roots #{statuses.inspect}"
        assert_predicate pipeline, :canceling?
      end

      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end
  end

  # Branch roots bypass the bulk path (resolve_step must evaluate the decision),
  # so they are the one enqueue that used to take a step lock without first
  # taking the pipeline lock. Against cancel — pipeline row, then pending steps
  # in scan order — that inverted order is a genuine cycle, because `branch`
  # emits a branch's arms before the branch step: cancel reaches an arm first
  # and waits on the branch step while the enqueue holds the branch step and
  # reaches for the arms. PostgreSQL then aborts one side with a deadlock, which
  # escaped Pipeline.run entirely.
  def test_cancel_racing_a_branch_root_enqueue_does_not_deadlock
    RACE_ITERATIONS.times do |iteration|
      # Runner commits the pipeline row before enqueueing its roots, so polling
      # for the committed record lands the cancel inside the enqueue window.
      # uncached is required: rails_promise runs inside the Rails executor,
      # which enables the query cache, and a repeated read would otherwise never
      # observe the other thread's commit.
      canceler = rails_promise do
        record = nil
        GoodPipeline::PipelineRecord.uncached do
          wait_until(timeout: 5, interval: 0.001) do
            record = GoodPipeline::PipelineRecord.where(type: "BranchRootPipeline").first
            record&.running?
          end
        end
        GoodPipeline::Coordinator.cancel_pipeline(record)
      end
      starter = rails_promise { BranchRootPipeline.run(choice: "go") }

      # value! re-raises in the caller, so an ActiveRecord::Deadlocked on either
      # side fails the test instead of being swallowed.
      starter.value!
      canceler.value!

      pipeline = GoodPipeline::PipelineRecord.where(type: "BranchRootPipeline").sole
      statuses = pipeline.steps.pluck(:coordination_status)

      if pipeline.terminal?
        assert_equal "halted", pipeline.status, "Iteration #{iteration}"
        refute_includes statuses, "pending",
                        "Iteration #{iteration}: terminal pipeline has pending steps #{statuses.inspect}"
      else
        assert_predicate pipeline, :canceling?, "Iteration #{iteration}: #{statuses.inspect}"
      end

      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end
  end

  private

  def user_job_count
    GoodJob::Job.where(job_class: "DownloadJob").count
  end

  def step_batch_count(steps)
    step_ids = steps.map { |step| step.id.to_s }
    GoodJob::BatchRecord.all.count { |batch| step_ids.include?(batch.properties[:step_id].to_s) }
  end
end
