# frozen_string_literal: true

require "active_record_test_helper"

class TestDependencyRecord < Minitest::Test
  include ActiveRecordTestCase

  # --- Diamond DAG graph navigation ---
  #
  #   A
  #  / \
  # B   C
  #  \ /
  #   D

  def test_diamond_dag_navigation
    pipeline = create_pipeline
    step_a = create_step(pipeline, key: "a")
    step_b = create_step(pipeline, key: "b")
    step_c = create_step(pipeline, key: "c")
    step_d = create_step(pipeline, key: "d")

    # B depends on A, C depends on A
    GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: step_b, depends_on_step: step_a)
    GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: step_c, depends_on_step: step_a)
    # D depends on B and C
    GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: step_d, depends_on_step: step_b)
    GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: step_d, depends_on_step: step_c)

    # A has no upstream steps
    assert_empty step_a.upstream_steps

    # A's downstream: B and C
    assert_equal %w[b c], step_a.downstream_steps.map(&:key).sort

    # B's upstream: A
    assert_equal ["a"], step_b.upstream_steps.map(&:key)

    # B's downstream: D
    assert_equal ["d"], step_b.downstream_steps.map(&:key)

    # D's upstream: B and C
    assert_equal %w[b c], step_d.upstream_steps.map(&:key).sort

    # D has no downstream
    assert_empty step_d.downstream_steps
  end
end
