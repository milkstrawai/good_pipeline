# frozen_string_literal: true

require "test_helper"

class TestBarrier < Minitest::Test
  Job = Class.new
  FIRST_BARRIER = :__good_pipeline_barrier_1 # rubocop:disable Naming/VariableNumber
  SECOND_BARRIER = :__good_pipeline_barrier_2 # rubocop:disable Naming/VariableNumber

  def test_compiles_phase_exits_through_barrier_to_phase_entries
    pipeline = build_pipeline do
      run :a, TestBarrier::Job
      run :b, TestBarrier::Job, after: :a
      run :c, TestBarrier::Job, after: :a
      barrier
      run :d, TestBarrier::Job
      run :e, TestBarrier::Job, after: :d
    end

    assert_equal [:a, :b, :c, FIRST_BARRIER, :d, :e], pipeline.step_definitions.map(&:key)
    assert_equal %i[b c], pipeline.steps_by_key.fetch(FIRST_BARRIER).dependencies
    assert_equal [FIRST_BARRIER], pipeline.steps_by_key.fetch(:d).dependencies
    assert_equal [:d], pipeline.steps_by_key.fetch(:e).dependencies
    assert_equal [:a], pipeline.root_steps.map(&:key)
  end

  def test_compiles_multiple_barriers_with_stable_keys
    pipeline = build_pipeline do
      run :a, TestBarrier::Job
      barrier
      run :b, TestBarrier::Job
      barrier
      run :c, TestBarrier::Job
    end

    assert_equal [:a], pipeline.steps_by_key.fetch(FIRST_BARRIER).dependencies
    assert_equal [FIRST_BARRIER], pipeline.steps_by_key.fetch(:b).dependencies
    assert_equal [:b], pipeline.steps_by_key.fetch(SECOND_BARRIER).dependencies
    assert_equal [SECOND_BARRIER], pipeline.steps_by_key.fetch(:c).dependencies
  end

  def test_explicit_earlier_phase_dependency_remains_additive
    pipeline = build_pipeline do
      run :a, TestBarrier::Job
      barrier
      run :b, TestBarrier::Job, after: :a
    end

    assert_equal [:a, FIRST_BARRIER], pipeline.steps_by_key.fetch(:b).dependencies
  end

  def test_same_phase_forward_reference_remains_valid
    pipeline = build_pipeline do
      run :b, TestBarrier::Job, after: :a
      run :a, TestBarrier::Job
      barrier
      run :c, TestBarrier::Job
    end

    assert_equal [:a], pipeline.steps_by_key.fetch(:b).dependencies
    assert_equal [:b], pipeline.steps_by_key.fetch(FIRST_BARRIER).dependencies
  end

  def test_cross_barrier_forward_reference_is_rejected
    error = assert_raises(GoodPipeline::InvalidPipelineError) do
      build_pipeline do
        run :before, TestBarrier::Job, after: :after
        barrier
        run :after, TestBarrier::Job
      end
    end

    assert_equal "step :before cannot depend on later barrier phase step :after", error.message
  end

  def test_rejects_invalid_barrier_positions
    leading = assert_raises(GoodPipeline::InvalidPipelineError) do
      build_pipeline do
        barrier
        run :a, TestBarrier::Job
      end
    end
    trailing = assert_raises(GoodPipeline::InvalidPipelineError) do
      build_pipeline do
        run :a, TestBarrier::Job
        barrier
      end
    end
    consecutive = assert_raises(GoodPipeline::InvalidPipelineError) do
      build_pipeline do
        run :a, TestBarrier::Job
        barrier
        barrier
        run :b, TestBarrier::Job
      end
    end

    assert_equal "barrier must follow at least one step", leading.message
    assert_equal "barrier must be followed by at least one step", trailing.message
    assert_equal "consecutive barriers are not supported", consecutive.message
  end

  def test_rejects_barrier_outside_configure
    pipeline = build_pipeline { run :a, TestBarrier::Job }

    error = assert_raises(GoodPipeline::ConfigurationError) { pipeline.send(:barrier) }

    assert_equal "barrier can only be called inside configure", error.message
  end

  def test_rejects_barrier_inside_branch_arm
    error = assert_raises(GoodPipeline::ConfigurationError) do
      build_pipeline do
        branch :route, by: :pick do
          on(:yes) { barrier }
        end
      end
    end

    assert_equal "barrier is only supported at the top level of configure", error.message
  end

  def test_rejects_symbol_and_string_generated_key_collisions
    [FIRST_BARRIER, FIRST_BARRIER.to_s].each do |reserved_key|
      error = assert_raises(GoodPipeline::InvalidPipelineError) do
        build_pipeline do
          run reserved_key, TestBarrier::Job
          barrier
          run :finish, TestBarrier::Job
        end
      end

      assert_equal "step key :#{FIRST_BARRIER} is reserved for a generated barrier", error.message
    end
  end

  def test_barrier_after_branch_depends_on_arm_exits
    pipeline = build_pipeline do
      branch :route, by: :pick do
        on(:left) { run :left_a, TestBarrier::Job }
        on(:right) do
          run :right_a, TestBarrier::Job
          run :right_b, TestBarrier::Job, after: :right_a
        end
      end
      barrier
      run :finish, TestBarrier::Job
    end

    assert_equal %i[left_a right_b], pipeline.steps_by_key.fetch(FIRST_BARRIER).dependencies
    assert_equal [FIRST_BARRIER], pipeline.steps_by_key.fetch(:finish).dependencies
  end

  def test_barrier_after_all_empty_branch_depends_on_sentinel
    pipeline = build_pipeline do
      branch :route, by: :pick do
        on :skip
        on :archive
      end
      barrier
      run :finish, TestBarrier::Job
    end

    assert_equal [:route], pipeline.steps_by_key.fetch(FIRST_BARRIER).dependencies
  end

  def test_barrier_before_branch_gates_only_sentinel_and_preserves_metadata
    pipeline = build_pipeline do
      run :start, TestBarrier::Job
      barrier
      branch :route, by: :pick do
        on(:work) { run :work, TestBarrier::Job }
        on :skip
      end
    end

    route = pipeline.steps_by_key.fetch(:route)
    work = pipeline.steps_by_key.fetch(:work)

    assert_equal [FIRST_BARRIER], route.dependencies
    assert_equal [:route], work.dependencies
    assert_equal :pick, route.decides
    assert_equal [:skip], route.empty_arms
  end

  def test_barrier_before_all_empty_branch_preserves_following_dependency
    pipeline = build_pipeline do
      run :start, TestBarrier::Job
      barrier
      branch :route, by: :pick do
        on :skip
        on :archive
      end
      run :finish, TestBarrier::Job, after: :route
    end

    assert_equal [FIRST_BARRIER], pipeline.steps_by_key.fetch(:route).dependencies
    assert_equal [:route], pipeline.steps_by_key.fetch(:finish).dependencies
  end

  private

  def build_pipeline(&definition)
    Class.new(GoodPipeline::Pipeline) do
      define_method(:configure) do |**|
        instance_exec(&definition)
      end

      private

      def pick = :skip
    end.build
  end
end
