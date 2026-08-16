# frozen_string_literal: true

require "test_helper"

class TestIgnoreTransitiveExemption < ActiveSupport::TestCase
  def test_halt_with_ignore_exempts_transitive_descendants
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    step_c = build_step(pipeline, key: "c", dependencies: [step_b])
    step_a.update_columns(coordination_status: "enqueued")

    complete_step_for(step_a, succeeded: false)

    assert_equal "failed", step_a.reload.coordination_status

    step_b.reload
    step_c.reload

    refute_equal "skipped", step_b.coordination_status,
                 "Direct dependent of :ignore step should NOT be skipped"
    refute_equal "skipped", step_c.coordination_status,
                 "Transitive descendant of :ignore step should NOT be skipped"
  end

  def test_halt_with_ignore_still_skips_unrelated_steps
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    build_step(pipeline, key: "c", dependencies: [step_b])
    step_d = build_step(pipeline, key: "d")
    step_a.update_columns(coordination_status: "enqueued")

    complete_step_for(step_a, succeeded: false)

    assert_equal "skipped", step_d.reload.coordination_status,
                 "Unrelated step should still be skipped under :halt"
  end

  def test_halt_with_ignore_chain_completes_successfully
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", on_failure_strategy: "ignore", job_class: "FailingJob")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    step_c = build_step(pipeline, key: "c", dependencies: [step_b])

    GoodPipeline::Coordinator.try_enqueue_step(step_a.id)

    wait_until(timeout: 10) do
      perform_enqueued_jobs_inline
      pipeline.reload
      pipeline.terminal?
    end

    step_a.reload
    step_b.reload
    step_c.reload

    assert_equal "failed", step_a.coordination_status
    refute_equal "skipped", step_b.coordination_status,
                 "step_b should have been enqueued, not skipped"
    refute_equal "skipped", step_c.coordination_status,
                 "step_c should have been enqueued, not skipped"
  end

  # An exempted step can also depend on a step outside the :ignore cone. The
  # mass skip resolves that outside arm negatively without a callback, so halt
  # propagation must re-evaluate the survivor — otherwise it waits forever on
  # a decrement that never arrives and the pipeline never settles.
  def test_halt_with_ignore_skips_exempt_step_blocked_by_a_skipped_outside_arm
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b")
    step_d = build_step(pipeline, key: "d", dependencies: [step_a, step_b])
    step_a.update_columns(coordination_status: "enqueued")

    complete_step_for(step_a, succeeded: false)

    assert_equal "skipped", step_b.reload.coordination_status
    assert_equal "skipped", step_d.reload.coordination_status,
                 "Exempt step blocked by a skipped outside arm can never run and must be skipped"
    assert_equal "halted", pipeline.reload.status
  end

  def test_halt_with_ignore_diamond_dependency_all_exempt
    # A(ignore) -> B -> D
    # A(ignore) -> C -> D
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b", dependencies: [step_a])
    step_c = build_step(pipeline, key: "c", dependencies: [step_a])
    step_d = build_step(pipeline, key: "d", dependencies: [step_b, step_c])
    step_e = build_step(pipeline, key: "e")
    step_a.update_columns(coordination_status: "enqueued")

    complete_step_for(step_a, succeeded: false)

    step_b.reload
    step_c.reload
    step_d.reload
    step_e.reload

    refute_equal "skipped", step_b.coordination_status
    refute_equal "skipped", step_c.coordination_status
    refute_equal "skipped", step_d.coordination_status,
                 "Diamond descendant of :ignore step should NOT be skipped"
    assert_equal "skipped", step_e.coordination_status,
                 "Unrelated step should be skipped"
  end
end
