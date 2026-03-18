# frozen_string_literal: true

require "test_helper"

class TestGraphValidator < Minitest::Test
  DummyJob = Class.new

  def step(key, dependencies: [], **)
    GoodPipeline::StepDefinition.new(key: key, job_class: DummyJob, dependencies: dependencies, **)
  end

  # --- Empty pipeline ---

  def test_empty_pipeline_raises
    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::GraphValidator.validate!([])
    end
    assert_equal "pipeline has no steps", error.message
  end

  # --- Duplicate keys ---

  def test_duplicate_step_key_raises
    steps = [step(:download), step(:download)]

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::GraphValidator.validate!(steps)
    end
    assert_equal "duplicate step key :download", error.message
  end

  # --- Self-dependencies ---

  def test_self_dependency_raises
    steps = [step(:transcode, dependencies: :transcode)]

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::GraphValidator.validate!(steps)
    end
    assert_equal "step :transcode depends on itself", error.message
  end

  # --- Unknown references ---

  def test_unknown_after_reference_raises
    steps = [step(:publish, dependencies: :missing)]

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::GraphValidator.validate!(steps)
    end
    assert_equal "step :publish references unknown dependency :missing", error.message
  end

  def test_unknown_reference_in_fan_in
    steps = [step(:a), step(:b, dependencies: %i[a missing])]

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::GraphValidator.validate!(steps)
    end
    assert_equal "step :b references unknown dependency :missing", error.message
  end

  # --- Cycles ---

  def test_direct_cycle_raises
    steps = [step(:a, dependencies: :b), step(:b, dependencies: :a)]

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::GraphValidator.validate!(steps)
    end
    assert_includes error.message, "cycle detected:"
  end

  def test_indirect_cycle_raises
    steps = [
      step(:a, dependencies: :c),
      step(:b, dependencies: :a),
      step(:c, dependencies: :b)
    ]

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::GraphValidator.validate!(steps)
    end
    assert_includes error.message, "cycle detected:"
  end

  def test_self_loop_caught_before_cycle_detector
    steps = [step(:a, dependencies: :a)]

    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      GoodPipeline::GraphValidator.validate!(steps)
    end
    assert_equal "step :a depends on itself", error.message
  end

  # --- Valid DAGs ---

  def test_single_step_no_dependencies
    GoodPipeline::GraphValidator.validate!([step(:a)])
  end

  def test_linear_chain_valid
    steps = [
      step(:a),
      step(:b, dependencies: :a),
      step(:c, dependencies: :b)
    ]

    GoodPipeline::GraphValidator.validate!(steps)
  end

  def test_diamond_valid
    steps = [
      step(:a),
      step(:b, dependencies: :a),
      step(:c, dependencies: :a),
      step(:d, dependencies: %i[b c])
    ]

    GoodPipeline::GraphValidator.validate!(steps)
  end

  def test_fan_out_valid
    steps = [
      step(:a),
      step(:b, dependencies: :a),
      step(:c, dependencies: :a),
      step(:d, dependencies: :a)
    ]

    GoodPipeline::GraphValidator.validate!(steps)
  end

  def test_fan_in_valid
    steps = [
      step(:a),
      step(:b),
      step(:c),
      step(:d, dependencies: %i[a b c])
    ]

    GoodPipeline::GraphValidator.validate!(steps)
  end

  def test_multiple_roots_valid
    steps = [step(:a), step(:b), step(:c)]

    GoodPipeline::GraphValidator.validate!(steps)
  end

  def test_all_independent_steps_valid
    steps = [step(:a), step(:b), step(:c), step(:d)]

    GoodPipeline::GraphValidator.validate!(steps)
  end

  # --- Forward references ---

  def test_forward_reference_valid
    steps = [
      step(:b, dependencies: :a),
      step(:a)
    ]

    GoodPipeline::GraphValidator.validate!(steps)
  end

  def test_forward_reference_with_fan_in
    steps = [
      step(:d, dependencies: %i[a c]),
      step(:a),
      step(:b, dependencies: :a),
      step(:c)
    ]

    GoodPipeline::GraphValidator.validate!(steps)
  end

  # --- Design doc example ---

  def test_video_processing_pipeline_shape
    steps = [
      step(:download),
      step(:transcode, dependencies: :download),
      step(:thumbnail, dependencies: :download),
      step(:publish, dependencies: %i[transcode thumbnail]),
      step(:cleanup, dependencies: :publish)
    ]

    GoodPipeline::GraphValidator.validate!(steps)
  end
end
