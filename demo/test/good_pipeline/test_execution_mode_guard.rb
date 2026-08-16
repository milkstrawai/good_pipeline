# frozen_string_literal: true

require "test_helper"

# GoodPipeline supports GoodJob's DB-mediated execution modes: :external
# unconditionally, and the async variants whenever a durable wakeup exists —
# polling, or LISTEN/NOTIFY, whose deliveries are transactional and therefore
# land after commit. Only the absence of both is rejected. Inline execution runs
# a step's job before its coordination row is stamped; non-GoodJob adapters
# bypass batch coordination entirely; deferred enqueue loses batch context.
# Every check is keyed on the effective adapter, never on GoodJob's configured
# symbol, and is applied at boot and at each enqueue boundary.
class TestExecutionModeGuard < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  class InlineOverrideJob < ApplicationJob
    self.queue_adapter = GoodJob::Adapter.new(execution_mode: :inline)

    def perform(**); end
  end

  class ActiveJobInlineJob < ApplicationJob
    self.queue_adapter = :inline

    def perform(**); end
  end

  class AsyncOverrideJob < ApplicationJob
    def perform(**); end
  end

  class DeferredEnqueueJob < ApplicationJob
    # :always defers on every supported Rails: by symbol on 7.2/8.0, by
    # truthiness on 8.1+.
    self.enqueue_after_transaction_commit = :always if respond_to?(:enqueue_after_transaction_commit)

    def perform(**); end
  end

  # --- boot validation ---

  def test_boot_validation_rejects_inline_execution_mode
    with_configuration_override(:execution_mode, :inline) do
      error = assert_raises(GoodPipeline::ConfigurationError) do
        GoodPipeline.validate_good_job_configuration!
      end

      assert_match(/:inline execution mode/, error.message)
    end
  end

  def test_boot_validation_rejects_enqueue_after_transaction_commit
    with_configuration_override(:enqueue_after_transaction_commit, true) do
      error = assert_raises(GoodPipeline::ConfigurationError) do
        GoodPipeline.validate_good_job_configuration!
      end

      assert_match(/enqueue_after_transaction_commit/, error.message)
    end
  end

  def test_boot_validation_rejects_unpreserved_job_records
    original = GoodJob.preserve_job_records
    GoodJob.preserve_job_records = false

    assert_raises(GoodPipeline::ConfigurationError) do
      GoodPipeline.validate_good_job_configuration!
    end
  ensure
    GoodJob.preserve_job_records = original
  end

  def test_boot_validation_accepts_the_demo_configuration
    assert_nil GoodPipeline.validate_good_job_configuration!
  end

  def test_boot_validation_rejects_effective_async_with_no_wakeup_channel_at_all
    with_configuration_override(:execution_mode, :async_all) do
      with_configuration_override(:enable_listen_notify, false) do
        [0, -1].each do |interval|
          with_configuration_override(:poll_interval, interval) do
            error = assert_raises(GoodPipeline::ConfigurationError, "interval #{interval} must be rejected") do
              GoodPipeline.validate_good_job_configuration!
            end

            assert_match(/wakeup channel/, error.message)
          end
        end
      end
    end
  end

  # PostgreSQL delivers NOTIFY at commit, so LISTEN/NOTIFY alone is a durable
  # wakeup for work enqueued inside a transaction — the poller is one recovery,
  # not the only possible one.
  def test_boot_validation_accepts_effective_async_without_polling_when_listen_notify_is_on
    with_configuration_override(:execution_mode, :async_all) do
      with_configuration_override(:enable_listen_notify, true) do
        with_configuration_override(:poll_interval, -1) do
          assert_nil GoodPipeline.validate_good_job_configuration!
        end
      end
    end
  end

  # GoodJob reports execution_mode :inline for any application that leaves the
  # mode unset under Rails.env.test?, but that value is only ever consulted by a
  # GoodJob adapter. An application on Active Job's :test adapter is not
  # executing anything inline, so boot must not abort for it; the adapter is
  # rejected precisely at the enqueue boundary instead.
  def test_boot_validation_ignores_the_configured_mode_for_a_non_good_job_adapter
    with_configuration_override(:execution_mode, :inline) do
      with_job_adapter(ActiveJob::Base, ActiveJob::QueueAdapters::TestAdapter.new) do
        assert_nil GoodPipeline.validate_good_job_configuration!
      end
    end
  end

  def test_boot_validation_accepts_effective_async_with_polling
    with_configuration_override(:execution_mode, :async_all) do
      with_configuration_override(:poll_interval, 10) do
        assert_nil GoodPipeline.validate_good_job_configuration!
      end
    end
  end

  # :async outside a webserver behaves as :external, so no poller is required
  # in this (non-webserver) test process — the check is effective-mode based.
  def test_boot_validation_accepts_configured_async_outside_a_webserver_without_polling
    with_configuration_override(:execution_mode, :async) do
      with_configuration_override(:poll_interval, 0) do
        assert_nil GoodPipeline.validate_good_job_configuration!
      end
    end
  end

  # --- enqueue-boundary guards: step job classes ---

  def test_per_class_good_job_inline_adapter_fails_the_step_at_enqueue
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a", job_class: "TestExecutionModeGuard::InlineOverrideJob")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    assert_equal "failed", step.coordination_status
    assert_match(/:inline execution mode/, step.error_message)
    assert_equal "failed", pipeline.reload.status
  end

  def test_per_class_good_job_inline_adapter_fails_the_step_in_bulk
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a", job_class: "TestExecutionModeGuard::InlineOverrideJob")

    GoodPipeline::Coordinator.bulk_enqueue_steps([step.id])

    assert_equal "failed", step.reload.coordination_status
    assert_equal "failed", pipeline.reload.status
  end

  # A non-GoodJob adapter would run the job unbatched while the step batch
  # finishes empty. Assertions are scoped to user-job and step-batch rows: the
  # settlement legitimately enqueues PipelineCallbackJob.
  def test_non_good_job_adapter_fails_the_step_at_enqueue
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a", job_class: "TestExecutionModeGuard::ActiveJobInlineJob")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    assert_equal "failed", step.coordination_status
    assert_match(/requires a GoodJob adapter/, step.error_message)
    assert_equal 0, GoodJob::Job.where(job_class: "TestExecutionModeGuard::ActiveJobInlineJob").count
    assert_equal 0, step_batch_count([step])
  end

  def test_per_class_deferred_enqueue_fails_the_step_at_enqueue
    skip "enqueue_after_transaction_commit not available" unless ApplicationJob.respond_to?(:enqueue_after_transaction_commit)

    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a", job_class: "TestExecutionModeGuard::DeferredEnqueueJob")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    assert_equal "failed", step.coordination_status
    assert_match(/defers enqueue until after commit/, step.error_message)
  end

  def test_per_class_async_adapter_with_no_wakeup_channel_fails_the_step_at_enqueue
    # A real :async_all adapter would start in-process executors against the
    # test database; a stubbed effective-async adapter exercises the same
    # guard branch without them.
    async_adapter = GoodJob::Adapter.new(execution_mode: :external)
    async_adapter.define_singleton_method(:execute_async?) { true }

    with_configuration_override(:poll_interval, 0) do
      with_configuration_override(:enable_listen_notify, false) do
        with_job_adapter(AsyncOverrideJob, async_adapter) do
          pipeline = create_pipeline(on_failure_strategy: "continue")
          pipeline.update_columns(status: "running")
          step = build_step(pipeline, key: "a", job_class: "TestExecutionModeGuard::AsyncOverrideJob")

          GoodPipeline::Coordinator.try_enqueue_step(step.id)

          step.reload

          assert_equal "failed", step.coordination_status
          assert_match(/LISTEN\/NOTIFY/, step.error_message)
        end
      end
    end
  end

  # --- enqueue-boundary guards: coordination job classes ---

  def test_overridden_step_finished_job_adapter_fails_the_step_on_the_single_path
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a")

    with_job_adapter(GoodPipeline::StepFinishedJob, ActiveJob::QueueAdapters::InlineAdapter.new) do
      GoodPipeline::Coordinator.try_enqueue_step(step.id)
    end

    step.reload

    assert_equal "failed", step.coordination_status
    assert_match(/StepFinishedJob/, step.error_message)
  end

  def test_overridden_step_finished_job_adapter_fails_all_steps_on_the_bulk_path
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    steps = [build_step(pipeline, key: "a"), build_step(pipeline, key: "b")]

    with_job_adapter(GoodPipeline::StepFinishedJob, ActiveJob::QueueAdapters::InlineAdapter.new) do
      GoodPipeline::Coordinator.bulk_enqueue_steps(steps.map(&:id))
    end

    steps.each do |step|
      assert_equal "failed", step.reload.coordination_status
      assert_match(/StepFinishedJob/, step.error_message)
    end
    assert_equal "failed", pipeline.reload.status
    assert_equal 0, GoodJob::Job.where(job_class: "DownloadJob").count
    assert_equal 0, step_batch_count(steps)
  end

  def test_unsupported_global_adapter_fails_all_steps_on_the_bulk_path
    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    steps = [build_step(pipeline, key: "a"), build_step(pipeline, key: "b")]

    with_job_adapter(ActiveJob::Base, ActiveJob::QueueAdapters::InlineAdapter.new) do
      GoodPipeline::Coordinator.bulk_enqueue_steps(steps.map(&:id))
    end

    steps.each { |step| assert_equal "failed", step.reload.coordination_status }
    pipeline.reload

    assert_equal "failed", pipeline.status
    assert_equal 0, GoodJob::Job.where(job_class: "DownloadJob").count
    assert_equal 0, step_batch_count(steps)
    # Settlement committed even though its callback dispatch was skipped: the
    # callback job class inherited the unsupported global adapter.
    assert_not_nil pipeline.callbacks_dispatched_at
  end

  # --- callback dispatch: skip, never roll back settlement ---

  def test_callback_dispatch_skips_for_a_good_job_inline_adapter
    assert_callback_dispatch_skipped(GoodJob::Adapter.new(execution_mode: :inline))
  end

  def test_callback_dispatch_skips_for_a_non_good_job_adapter
    assert_callback_dispatch_skipped(ActiveJob::QueueAdapters::InlineAdapter.new)
  end

  def test_callback_dispatch_skips_for_a_deferred_callback_job
    skip "enqueue_after_transaction_commit not available" unless ApplicationJob.respond_to?(:enqueue_after_transaction_commit)

    original = GoodPipeline::PipelineCallbackJob.enqueue_after_transaction_commit
    GoodPipeline::PipelineCallbackJob.enqueue_after_transaction_commit = :always

    assert_callback_dispatch_skipped(nil)
  ensure
    GoodPipeline::PipelineCallbackJob.enqueue_after_transaction_commit = original
  end

  # --- version-gated deferral mapping (table-driven; independent of the
  # --- Rails version the suite happens to run under) ---

  def test_deferral_mapping_across_rails_versions # rubocop:disable Metrics/MethodLength
    cases = [
      # [rails version, per-class setting, adapter defers?, expected]
      ["7.2.0", :always,  false, true],
      ["7.2.0", :never,   false, false],
      ["7.2.0", :default, true,  true],   # :default consults the adapter — defers
      ["7.2.0", :default, false, false],  # :default consults the adapter — does not
      ["8.0.0", :always,  true,  true],
      ["8.0.0", :never,   true,  false],  # adapter consultation removed
      ["8.0.0", :default, true,  false],  # adapter consultation removed
      ["8.0.0", true,     false, true],
      ["8.0.0", false,    true,  false],
      ["8.1.0", true,     false, true],
      ["8.1.0", false,    true,  false],
      ["8.1.0", :always,  false, true],   # truthiness: legacy symbols all defer
      ["8.1.0", :never,   false, true],   # truthiness footgun
      ["8.1.0", :default, false, true]    # truthiness footgun
    ]

    cases.each do |version, setting, adapter_defers, expected|
      job_class = fake_job_class(setting)
      adapter = fake_adapter(adapter_defers)
      actual = GoodPipeline::Coordinator.send(
        :defers_enqueue_past_commit?, job_class, adapter, gem_version: Gem::Version.new(version)
      )

      assert_equal expected, actual,
                   "Rails #{version}, setting #{setting.inspect}, adapter #{adapter_defers}: expected #{expected}"
    end
  end

  private

  def assert_callback_dispatch_skipped(adapter)
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    build_step(pipeline, key: "a").update_columns(coordination_status: "succeeded")
    callback_jobs = -> { GoodJob::Job.where(job_class: "GoodPipeline::PipelineCallbackJob").count }
    before = callback_jobs.call

    if adapter
      with_job_adapter(GoodPipeline::PipelineCallbackJob, adapter) do
        GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
      end
    else
      GoodPipeline::Coordinator.recompute_pipeline_status(pipeline.reload)
    end

    pipeline.reload

    assert_equal "succeeded", pipeline.status
    assert_not_nil pipeline.callbacks_dispatched_at
    assert_equal before, callback_jobs.call
  end

  def fake_job_class(setting)
    Class.new do
      define_singleton_method(:enqueue_after_transaction_commit) { setting }
    end
  end

  def fake_adapter(defers)
    Class.new do
      define_method(:enqueue_after_transaction_commit?) { defers }
    end.new
  end

  def step_batch_count(steps)
    step_ids = steps.map { |step| step.id.to_s }
    GoodJob::BatchRecord.all.count { |batch| step_ids.include?(batch.properties[:step_id].to_s) }
  end

  # GoodJob.configuration is a long-lived instance; shadow one reader on its
  # singleton and remove the shadow afterwards, restoring the class method.
  def with_configuration_override(method, value)
    GoodJob.configuration.define_singleton_method(method) { value }
    yield
  ensure
    GoodJob.configuration.singleton_class.remove_method(method)
  end

  def with_job_adapter(job_class, adapter)
    original = job_class.queue_adapter
    job_class.queue_adapter = adapter
    yield
  ensure
    job_class.queue_adapter = original
  end
end
