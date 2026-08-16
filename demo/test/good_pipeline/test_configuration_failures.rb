# frozen_string_literal: true

require "test_helper"

# Class names stored on pipeline/step rows outlive the code that defined them.
# Every resolution site must route NameError through coordinated failure while
# preserving its original metadata, instead of letting it escape
# StepFinishedJob and wedge the pipeline in `running`.
class TestConfigurationFailures < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  class ConstructorFailure < StandardError; end

  class RaisingConstructorJob < ApplicationJob
    def initialize(...) # rubocop:disable Lint/MissingSuper
      raise ConstructorFailure, "job constructor rejected stored arguments"
    end

    def perform(**); end
  end

  class SerializationFailure < StandardError; end

  class RaisingSerializationJob < ApplicationJob
    def serialize
      raise SerializationFailure, "job serialization rejected stored payload"
    end

    def perform(**); end
  end

  class ConcurrencyRejectedJob < ApplicationJob
    before_enqueue { throw :abort }

    def self.good_job_concurrency_config = { total_limit: 1 }
    def good_job_concurrency_key = "good-pipeline-rejected-enqueue"

    def perform(**); end
  end

  def test_missing_job_class_fails_the_step_instead_of_raising
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a", job_class: "RemovedJob")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    assert_equal "failed", step.coordination_status
    assert_equal "NameError", step.error_class
    assert_match(/RemovedJob/, step.error_message)
    assert_equal "failed", pipeline.reload.status
  end

  def test_missing_pipeline_class_fails_the_step_instead_of_raising
    pipeline = create_pipeline(type: "RemovedPipeline", on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    assert_equal "failed", step.reload.coordination_status
    assert_equal "NameError", step.error_class
    assert_equal "failed", pipeline.reload.status
  end

  def test_missing_pipeline_class_on_a_branch_step_fails_the_step # rubocop:disable Metrics/MethodLength
    pipeline = create_pipeline(type: "RemovedPipeline", on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(
      pipeline,
      key: "decision",
      job_class: GoodPipeline::BRANCH_JOB_CLASS,
      branch: { "decides" => "choose_arm" }
    )

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    assert_equal "failed", step.reload.coordination_status
    assert_equal "NameError", step.error_class
    assert_equal "failed", pipeline.reload.status
  end

  def test_all_roots_failing_configuration_settles_the_pipeline_instead_of_wedging_it
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", job_class: "RemovedJob")
    step_b = build_step(pipeline, key: "b", job_class: "AlsoRemovedJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])

    assert_equal "failed", step_a.reload.coordination_status
    assert_equal "failed", step_b.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  # Under :halt, the first failure's propagation skips the second pending
  # step; the fresh conditional re-claim must then leave it `skipped` rather
  # than stamping `failed` over it through a stale in-memory record.
  def test_bulk_multi_failure_under_halt_leaves_later_steps_skipped
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", job_class: "RemovedJob")
    step_b = build_step(pipeline, key: "b", job_class: "AlsoRemovedJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step_a.id, step_b.id])

    statuses = [step_a.reload.coordination_status, step_b.reload.coordination_status].sort

    assert_equal %w[failed skipped], statuses
    assert_equal "halted", pipeline.reload.status
  end

  def test_bulk_failure_cascades_skips_to_dependents
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    root = build_step(pipeline, key: "root", job_class: "RemovedJob")
    child = build_step(pipeline, key: "child", dependencies: [root])

    GoodPipeline::Coordinator.bulk_enqueue_steps([root.id])

    assert_equal "failed", root.reload.coordination_status
    assert_equal "skipped", child.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  def test_deterministic_root_job_constructor_failure_is_recorded_and_settles_dependents # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    root = build_step(
      pipeline,
      key: "root",
      job_class: "TestConfigurationFailures::RaisingConstructorJob"
    )
    child = build_step(pipeline, key: "child", dependencies: [root])

    GoodPipeline::Coordinator.bulk_enqueue_steps([root.id])

    assert_equal "failed", root.reload.coordination_status
    assert_equal "TestConfigurationFailures::ConstructorFailure", root.error_class
    assert_equal "job constructor rejected stored arguments", root.error_message
    assert_equal "skipped", child.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
    assert_equal 0, GoodJob::Job.where(job_class: root.job_class).count
  end

  def test_malformed_stored_arguments_fail_through_the_single_step_path # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    root = build_step(pipeline, key: "root")
    child = build_step(pipeline, key: "child", dependencies: [root])
    child.update_column(:params, %w[not an object])
    root.update_columns(coordination_status: "enqueued", good_job_batch_id: SecureRandom.uuid)

    complete_step_for(root, succeeded: true)

    assert_equal "failed", child.reload.coordination_status
    assert_equal "ArgumentError", child.error_class
    assert_match(/stored params.*must be a JSON object/, child.error_message)
    assert_equal "failed", pipeline.reload.status
  end

  def test_invalid_stored_enqueue_option_is_a_visible_deterministic_failure # rubocop:disable Metrics/AbcSize
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "root", enqueue_options: { "wait" => "not-a-duration" })
    expected_error = invalid_wait_error

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    assert_equal "failed", step.reload.coordination_status
    assert_equal expected_error.class.name, step.error_class
    assert_equal expected_error.message, step.error_message
    assert_equal "failed", pipeline.reload.status
  end

  def test_serialization_failure_preserves_original_metadata_without_inserting_a_job # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(
      pipeline,
      key: "root",
      job_class: "TestConfigurationFailures::RaisingSerializationJob"
    )

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    assert_equal "failed", step.reload.coordination_status
    assert_equal "TestConfigurationFailures::SerializationFailure", step.error_class
    assert_equal "job serialization rejected stored payload", step.error_message
    assert_equal "failed", pipeline.reload.status
    assert_equal 0, GoodJob::Job.where(job_class: step.job_class).count
  end

  def test_bulk_concurrency_rejection_never_leaves_a_step_enqueued_without_a_job # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(
      pipeline,
      key: "root",
      job_class: "TestConfigurationFailures::ConcurrencyRejectedJob"
    )

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    assert_equal "failed", step.reload.coordination_status
    assert_equal "ActiveJob::EnqueueError", step.error_class
    assert_match(/did not persist a GoodJob row/, step.error_message)
    assert_nil step.good_job_id
    assert_nil step.good_job_batch_id
    assert_equal "failed", pipeline.reload.status
    assert_equal 0, GoodJob::Job.where(job_class: step.job_class).count
    refute(GoodJob::BatchRecord.all.any? { |batch| batch.properties[:step_id].to_s == step.id.to_s })
  end

  # A configuration failure reaches a terminal state without a StepFinishedJob
  # callback, so it must decrement its dependents' upstream counts itself.
  # Under :ignore with a fan-in dependent, missing that decrement leaves the
  # dependent waiting on a count that never reaches zero once the other
  # upstream completes — pipeline wedged in `running`.
  def test_ignore_config_failure_does_not_strand_fan_in_dependents # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step_a = build_step(pipeline, key: "a", job_class: "RemovedJob", on_failure_strategy: "ignore")
    step_b = build_step(pipeline, key: "b")
    step_d = build_step(pipeline, key: "d", dependencies: [step_a, step_b])

    GoodPipeline::Coordinator.try_enqueue_step(step_a.id)

    assert_equal "failed", step_a.reload.coordination_status

    step_b.update_columns(coordination_status: "enqueued")
    complete_step_for(step_b, succeeded: true)

    step_d.reload

    assert_equal "enqueued", step_d.coordination_status,
                 "Fan-in dependent should run; recorded #{step_d.error_class}: #{step_d.error_message}"

    complete_step_for(step_d, succeeded: true)

    assert_equal "failed", pipeline.reload.status
  end

  def test_missing_pipeline_class_does_not_roll_back_settlement
    pipeline = create_pipeline(type: "RemovedPipeline", on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: "a").update_columns(coordination_status: "succeeded")

    GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)

    pipeline.reload

    assert_equal "succeeded", pipeline.status
    assert_not_nil pipeline.callbacks_dispatched_at
  end

  private

  def invalid_wait_error
    Time.current.public_send(:+, "not-a-duration")
  rescue StandardError => error
    error
  end
end
