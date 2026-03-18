# frozen_string_literal: true

require "test_helper"

class TestCycleDetector < Minitest::Test
  def test_linear_chain_no_cycle
    steps = { a: true, b: true, c: true }
    edges = { a: [:b], b: [:c] }

    GoodPipeline::CycleDetector.check!(steps, edges)
  end

  def test_diamond_dag_no_cycle
    steps = { a: true, b: true, c: true, d: true }
    edges = { a: %i[b c], b: [:d], c: [:d] }

    GoodPipeline::CycleDetector.check!(steps, edges)
  end

  def test_single_node_no_cycle
    steps = { a: true }
    edges = {}

    GoodPipeline::CycleDetector.check!(steps, edges)
  end

  def test_disconnected_components_no_cycle
    steps = { a: true, b: true, c: true, d: true }
    edges = { a: [:b], c: [:d] }

    GoodPipeline::CycleDetector.check!(steps, edges)
  end

  def test_direct_cycle_two_nodes
    steps = { a: true, b: true }
    edges = { a: [:b], b: [:a] }

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::CycleDetector.check!(steps, edges)
    end
    assert_match(/:a/, error.message)
    assert_match(/:b/, error.message)
  end

  def test_indirect_cycle_three_nodes
    steps = { a: true, b: true, c: true }
    edges = { a: [:b], b: [:c], c: [:a] }

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::CycleDetector.check!(steps, edges)
    end
    assert_equal "cycle detected: :a -> :b -> :c -> :a", error.message
  end

  def test_self_loop
    steps = { a: true }
    edges = { a: [:a] }

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::CycleDetector.check!(steps, edges)
    end
    assert_equal "cycle detected: :a -> :a", error.message
  end

  def test_cycle_in_one_component_of_many
    steps = { a: true, b: true, c: true, d: true }
    edges = { a: [:b], c: [:d], d: [:c] }

    assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::CycleDetector.check!(steps, edges)
    end
  end

  def test_cycle_error_includes_path
    steps = { a: true, b: true }
    edges = { a: [:b], b: [:a] }

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::CycleDetector.check!(steps, edges)
    end
    assert_includes error.message, "cycle detected:"
    assert_includes error.message, "->"
  end
end
