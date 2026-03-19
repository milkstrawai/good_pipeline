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

    # A has no upstream dependencies
    assert_empty step_a.upstream_dependencies

    # A's downstream: B and C depend on A
    downstream_of_a = step_a.downstream_dependencies.map { |d| d.step.key }
    assert_equal %w[b c], downstream_of_a.sort

    # B's upstream: depends on A
    upstream_of_b = step_b.upstream_dependencies.map { |d| d.depends_on_step.key }
    assert_equal ["a"], upstream_of_b

    # B's downstream: D depends on B
    downstream_of_b = step_b.downstream_dependencies.map { |d| d.step.key }
    assert_equal ["d"], downstream_of_b

    # D's upstream: depends on B and C
    upstream_of_d = step_d.upstream_dependencies.map { |d| d.depends_on_step.key }
    assert_equal %w[b c], upstream_of_d.sort

    # D has no downstream
    assert_empty step_d.downstream_dependencies
  end
end
