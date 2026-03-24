# frozen_string_literal: true

require "test_helper"

class TestStepRecord < ActiveSupport::TestCase
  # --- Defaults ---

  def test_default_coordination_status_is_pending
    pipeline = create_pipeline
    step = create_step(pipeline)

    assert_equal "pending", step.coordination_status
  end

  # --- UUID primary key ---

  def test_id_is_uuid
    pipeline = create_pipeline
    step = create_step(pipeline)

    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, step.id)
  end

  # --- terminal_coordination_status? ---

  def test_terminal_returns_false_for_pending
    pipeline = create_pipeline
    step = create_step(pipeline)

    refute_predicate step, :terminal_coordination_status?
  end

  def test_terminal_returns_false_for_enqueued
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.update_columns(coordination_status: "enqueued")

    refute_predicate step, :terminal_coordination_status?
  end

  def test_terminal_returns_true_for_succeeded
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.update_columns(coordination_status: "succeeded")

    assert_predicate step, :terminal_coordination_status?
  end

  def test_terminal_returns_true_for_failed
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.update_columns(coordination_status: "failed")

    assert_predicate step, :terminal_coordination_status?
  end

  def test_terminal_returns_true_for_skipped
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.update_columns(coordination_status: "skipped")

    assert_predicate step, :terminal_coordination_status?
  end

  # --- transition_coordination_status_to! valid transitions ---

  def test_transition_pending_to_enqueued
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:enqueued)

    assert_equal "enqueued", step.coordination_status
  end

  def test_transition_pending_to_skipped
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:skipped)

    assert_equal "skipped", step.coordination_status
  end

  def test_transition_enqueued_to_succeeded
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:enqueued)
    step.transition_coordination_status_to!(:succeeded)

    assert_equal "succeeded", step.coordination_status
  end

  def test_transition_enqueued_to_failed
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:enqueued)
    step.transition_coordination_status_to!(:failed)

    assert_equal "failed", step.coordination_status
  end

  # --- transition_coordination_status_to! invalid transitions ---

  def test_transition_pending_to_succeeded_allowed_for_branch_steps
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:succeeded)

    assert_equal "succeeded", step.coordination_status
  end

  def test_transition_pending_to_failed_allowed_for_branch_resolution_failures
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:failed)

    assert_equal "failed", step.coordination_status
  end

  def test_transition_enqueued_to_pending_raises
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:enqueued)
    assert_raises(GoodPipeline::InvalidTransition) do
      step.transition_coordination_status_to!(:pending)
    end
  end

  def test_transition_enqueued_to_skipped_raises
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:enqueued)
    assert_raises(GoodPipeline::InvalidTransition) do
      step.transition_coordination_status_to!(:skipped)
    end
  end

  def test_transition_from_terminal_succeeded_raises
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.update_columns(coordination_status: "succeeded")
    step.reload
    assert_raises(GoodPipeline::InvalidTransition) do
      step.transition_coordination_status_to!(:enqueued)
    end
  end

  def test_transition_from_terminal_failed_raises
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.update_columns(coordination_status: "failed")
    step.reload
    assert_raises(GoodPipeline::InvalidTransition) do
      step.transition_coordination_status_to!(:enqueued)
    end
  end

  def test_transition_from_terminal_skipped_raises
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.update_columns(coordination_status: "skipped")
    step.reload
    assert_raises(GoodPipeline::InvalidTransition) do
      step.transition_coordination_status_to!(:enqueued)
    end
  end

  # --- Error message includes step key ---

  def test_error_message_includes_step_key
    pipeline = create_pipeline
    step = create_step(pipeline, key: "transcode")
    step.transition_coordination_status_to!(:enqueued)
    error = assert_raises(GoodPipeline::InvalidTransition) do
      step.transition_coordination_status_to!(:pending)
    end

    assert_includes error.message, "transcode"
    assert_includes error.message, "from 'enqueued' to 'pending'"
  end

  # --- Accepts symbols ---

  def test_transition_accepts_symbols
    pipeline = create_pipeline
    step = create_step(pipeline)
    step.transition_coordination_status_to!(:enqueued)

    assert_equal "enqueued", step.coordination_status
  end

  # --- Unique constraint on (pipeline_id, key) ---

  def test_duplicate_key_within_pipeline_raises
    pipeline = create_pipeline
    create_step(pipeline, key: "download")
    assert_raises(ActiveRecord::RecordNotUnique) do
      create_step(pipeline, key: "download", job_class: "OtherJob")
    end
  end

  def test_same_key_in_different_pipelines_allowed
    pipeline_a = create_pipeline(type: "PipelineA")
    pipeline_b = create_pipeline(type: "PipelineB")
    create_step(pipeline_a, key: "download")
    create_step(pipeline_b, key: "download")

    assert_equal 1, pipeline_a.steps.count
    assert_equal 1, pipeline_b.steps.count
  end
end
