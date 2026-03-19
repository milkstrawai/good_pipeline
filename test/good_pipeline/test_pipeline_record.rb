# frozen_string_literal: true

require "active_record_test_helper"

class TestPipelineRecord < Minitest::Test
  include ActiveRecordTestCase

  # --- Defaults ---

  def test_default_status_is_pending
    pipeline = create_pipeline
    assert_equal "pending", pipeline.status
  end

  def test_default_halt_triggered_is_false
    pipeline = create_pipeline
    assert_equal false, pipeline.halt_triggered
  end

  def test_default_params_is_empty_hash
    pipeline = create_pipeline
    assert_equal({}, pipeline.params)
  end

  # --- UUID primary key ---

  def test_id_is_uuid
    pipeline = create_pipeline
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, pipeline.id)
  end

  # --- STI disabled ---

  def test_type_column_does_not_trigger_sti
    pipeline = create_pipeline(type: "VideoProcessingPipeline")
    reloaded = GoodPipeline::PipelineRecord.find(pipeline.id)
    assert_instance_of GoodPipeline::PipelineRecord, reloaded
    assert_equal "VideoProcessingPipeline", reloaded.type
  end

  # --- terminal? ---

  def test_terminal_returns_false_for_pending
    pipeline = create_pipeline
    refute pipeline.terminal?
  end

  def test_terminal_returns_false_for_running
    pipeline = create_pipeline
    pipeline.update_columns(status: "running")
    refute pipeline.terminal?
  end

  def test_terminal_returns_true_for_succeeded
    pipeline = create_pipeline
    pipeline.update_columns(status: "succeeded")
    assert pipeline.terminal?
  end

  def test_terminal_returns_true_for_failed
    pipeline = create_pipeline
    pipeline.update_columns(status: "failed")
    assert pipeline.terminal?
  end

  def test_terminal_returns_true_for_halted
    pipeline = create_pipeline
    pipeline.update_columns(status: "halted")
    assert pipeline.terminal?
  end

  def test_terminal_returns_true_for_skipped
    pipeline = create_pipeline
    pipeline.update_columns(status: "skipped")
    assert pipeline.terminal?
  end

  # --- transition_to! valid transitions ---

  def test_transition_pending_to_running
    pipeline = create_pipeline
    pipeline.transition_to!(:running)
    assert_equal "running", pipeline.status
  end

  def test_transition_pending_to_skipped
    pipeline = create_pipeline
    pipeline.transition_to!(:skipped)
    assert_equal "skipped", pipeline.status
  end

  def test_transition_running_to_succeeded
    pipeline = create_pipeline
    pipeline.transition_to!(:running)
    pipeline.transition_to!(:succeeded)
    assert_equal "succeeded", pipeline.status
  end

  def test_transition_running_to_failed
    pipeline = create_pipeline
    pipeline.transition_to!(:running)
    pipeline.transition_to!(:failed)
    assert_equal "failed", pipeline.status
  end

  def test_transition_running_to_halted
    pipeline = create_pipeline
    pipeline.transition_to!(:running)
    pipeline.transition_to!(:halted)
    assert_equal "halted", pipeline.status
  end

  # --- transition_to! invalid transitions ---

  def test_transition_pending_to_succeeded_raises
    pipeline = create_pipeline
    error = assert_raises(GoodPipeline::InvalidTransition) { pipeline.transition_to!(:succeeded) }
    assert_includes error.message, "cannot transition pipeline from 'pending' to 'succeeded'"
  end

  def test_transition_pending_to_failed_raises
    pipeline = create_pipeline
    error = assert_raises(GoodPipeline::InvalidTransition) { pipeline.transition_to!(:failed) }
    assert_includes error.message, "from 'pending' to 'failed'"
  end

  def test_transition_running_to_pending_raises
    pipeline = create_pipeline
    pipeline.transition_to!(:running)
    assert_raises(GoodPipeline::InvalidTransition) { pipeline.transition_to!(:pending) }
  end

  def test_transition_from_terminal_succeeded_raises
    pipeline = create_pipeline
    pipeline.update_columns(status: "succeeded")
    pipeline.reload
    assert_raises(GoodPipeline::InvalidTransition) { pipeline.transition_to!(:running) }
  end

  def test_transition_from_terminal_failed_raises
    pipeline = create_pipeline
    pipeline.update_columns(status: "failed")
    pipeline.reload
    assert_raises(GoodPipeline::InvalidTransition) { pipeline.transition_to!(:running) }
  end

  def test_transition_from_terminal_halted_raises
    pipeline = create_pipeline
    pipeline.update_columns(status: "halted")
    pipeline.reload
    assert_raises(GoodPipeline::InvalidTransition) { pipeline.transition_to!(:running) }
  end

  def test_transition_from_terminal_skipped_raises
    pipeline = create_pipeline
    pipeline.update_columns(status: "skipped")
    pipeline.reload
    assert_raises(GoodPipeline::InvalidTransition) { pipeline.transition_to!(:running) }
  end

  # --- transition_to! accepts symbols ---

  def test_transition_to_accepts_symbols
    pipeline = create_pipeline
    pipeline.transition_to!(:running)
    assert_equal "running", pipeline.status
  end
end
