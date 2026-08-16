# frozen_string_literal: true

require "test_helper"

# GoodPipeline supports GoodJob's DB-mediated execution modes. :external is
# always safe; an effective in-process async adapter additionally requires a
# positive poll interval. LISTEN/NOTIFY cannot recover a pre-commit local wakeup
# miss because GoodJob suppresses NOTIFY after it creates that local worker.
# Inline execution runs a step before its coordination row is stamped;
# non-GoodJob adapters bypass batch coordination; effective deferred enqueue
# loses batch context. The same validator runs at boot and enqueue boundaries.
class TestExecutionModeGuard < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  LISTEN_NOTIFY_SETTINGS = [true, false].freeze
  NONPOSITIVE_POLL_INTERVALS = [0, -1].freeze

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

  def test_boot_validation_uses_effective_deferral_instead_of_the_raw_good_job_setting
    with_configuration_override(:enqueue_after_transaction_commit, true) do
      if ActiveJob.gem_version < Gem::Version.new("8.0")
        error = assert_raises(GoodPipeline::ConfigurationError) do
          GoodPipeline.validate_good_job_configuration!
        end

        assert_match(/effectively defers enqueue/, error.message)
      else
        assert_nil GoodPipeline.validate_good_job_configuration!
      end
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

  def test_boot_validation_rejects_effective_async_without_positive_polling
    with_configuration_override(:execution_mode, :async_all) do
      LISTEN_NOTIFY_SETTINGS.product(NONPOSITIVE_POLL_INTERVALS).each do |listen_notify, interval|
        assert_boot_rejects_async_without_polling(listen_notify, interval)
      end
    end
  end

  def test_boot_validation_accepts_effective_async_with_positive_polling
    with_configuration_override(:execution_mode, :async_all) do
      LISTEN_NOTIFY_SETTINGS.each do |listen_notify|
        with_configuration_override(:enable_listen_notify, listen_notify) do
          with_configuration_override(:poll_interval, 10) do
            assert_nil GoodPipeline.validate_good_job_configuration!
          end
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
      with_configuration_override(:enqueue_after_transaction_commit, true) do
        with_job_adapter(ActiveJob::Base, ActiveJob::QueueAdapters::TestAdapter.new) do
          assert_nil GoodPipeline.validate_good_job_configuration!
        end
      end
    end
  end

  # :async and :async_server outside a webserver behave as :external, so no
  # poller is required in this process — the check is effective-mode based.
  def test_boot_validation_accepts_configured_webserver_async_modes_outside_a_webserver_without_polling
    %i[async async_server].each do |execution_mode|
      with_configuration_override(:execution_mode, execution_mode) do
        with_configuration_override(:poll_interval, 0) do
          assert_nil GoodPipeline.validate_good_job_configuration!
        end
      end
    end
  end

  def test_configured_webserver_async_modes_require_polling_when_effectively_in_process
    %i[async async_server].each do |execution_mode|
      with_configuration_override(:execution_mode, execution_mode) do
        with_configuration_override(:in_webserver?, true) do
          with_configuration_override(:poll_interval, 0) do
            error = assert_raises(GoodPipeline::ConfigurationError) do
              GoodPipeline.validate_good_job_configuration!
            end

            assert_match(/poll_interval > 0/, error.message)
          end
        end
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
    unless ApplicationJob.respond_to?(:enqueue_after_transaction_commit)
      skip "enqueue_after_transaction_commit not available"
    end

    pipeline = create_pipeline(on_failure_strategy: "continue")
    pipeline.update_columns(status: "running")
    step = build_step(pipeline, key: "a", job_class: "TestExecutionModeGuard::DeferredEnqueueJob")

    GoodPipeline::Coordinator.try_enqueue_step(step.id)

    step.reload

    assert_equal "failed", step.coordination_status
    assert_match(/defers enqueue until after commit/, step.error_message)
  end

  def test_per_class_async_adapter_without_positive_polling_fails_before_any_job_or_batch_is_inserted
    # A real :async_all adapter would start in-process executors against the
    # test database; a stubbed effective-async adapter exercises the same
    # guard branch without them.
    with_job_adapter(AsyncOverrideJob, effective_async_adapter) do
      LISTEN_NOTIFY_SETTINGS.product(NONPOSITIVE_POLL_INTERVALS).each do |listen_notify, interval|
        assert_async_step_rejected_before_insert(listen_notify, interval)
      end
    end
  end

  def test_per_class_effective_async_adapter_accepts_positive_polling_with_or_without_listen_notify
    with_job_adapter(AsyncOverrideJob, effective_async_adapter) do
      with_configuration_override(:poll_interval, 10) do
        LISTEN_NOTIFY_SETTINGS.each do |listen_notify|
          with_configuration_override(:enable_listen_notify, listen_notify) do
            assert_nil GoodPipeline::ExecutionConfiguration.validate_enqueue!(AsyncOverrideJob)
          end
        end
      end
    end
  end

  def test_boot_and_enqueue_boundary_share_the_async_polling_rule # rubocop:disable Metrics/MethodLength
    with_job_adapter(ActiveJob::Base, effective_async_adapter) do
      with_configuration_override(:poll_interval, 0) do
        with_configuration_override(:enable_listen_notify, true) do
          boot_error = assert_raises(GoodPipeline::ConfigurationError) do
            GoodPipeline.validate_good_job_configuration!
          end
          enqueue_error = assert_raises(GoodPipeline::ConfigurationError) do
            GoodPipeline::ExecutionConfiguration.validate_enqueue!(ActiveJob::Base)
          end

          assert_equal boot_error.message, enqueue_error.message
        end
      end
    end
  end

  def test_boot_and_enqueue_boundary_share_the_effective_deferral_rule
    with_enqueue_deferral_setting(ActiveJob::Base, :always) do
      boot_error = assert_raises(GoodPipeline::ConfigurationError) do
        GoodPipeline.validate_good_job_configuration!
      end
      enqueue_error = assert_raises(GoodPipeline::ConfigurationError) do
        GoodPipeline::ExecutionConfiguration.validate_enqueue!(ActiveJob::Base)
      end

      assert_equal boot_error.message, enqueue_error.message
      assert_match(/durable handoffs share the caller's transaction/, boot_error.message)
    end
  end

  def test_legacy_never_override_follows_the_installed_rails_boundary_semantics
    with_enqueue_deferral_setting(AsyncOverrideJob, :never) do
      if ActiveJob.gem_version >= Gem::Version.new("8.1")
        error = assert_raises(GoodPipeline::ConfigurationError) do
          GoodPipeline::ExecutionConfiguration.validate_enqueue!(AsyncOverrideJob)
        end

        assert_match(/effectively defers enqueue/, error.message)
      else
        assert_nil GoodPipeline::ExecutionConfiguration.validate_enqueue!(AsyncOverrideJob)
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

  def test_overridden_step_finished_job_adapter_fails_all_steps_on_the_bulk_path # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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

  def test_internal_job_validates_its_effective_adapter_at_the_actual_enqueue_boundary
    before = GoodJob::Job.where(job_class: "GoodPipeline::PipelineReconciliationJob").count

    with_job_adapter(GoodPipeline::PipelineReconciliationJob, ActiveJob::QueueAdapters::InlineAdapter.new) do
      error = assert_raises(GoodPipeline::ConfigurationError) do
        GoodPipeline::PipelineReconciliationJob.perform_later(nil, {})
      end

      assert_match(/requires a GoodJob adapter/, error.message)
    end

    assert_equal before, GoodJob::Job.where(job_class: "GoodPipeline::PipelineReconciliationJob").count
  end

  def test_unsupported_global_adapter_fails_all_steps_on_the_bulk_path # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
    unless ApplicationJob.respond_to?(:enqueue_after_transaction_commit)
      skip "enqueue_after_transaction_commit not available"
    end

    with_enqueue_deferral_setting(GoodPipeline::PipelineCallbackJob, :always) do
      assert_callback_dispatch_skipped(nil)
    end
  end

  # --- version-gated deferral mapping (table-driven; independent of the
  # --- Rails version the suite happens to run under) ---

  def test_deferral_mapping_across_rails_versions # rubocop:disable Metrics/MethodLength
    cases = [
      # [rails version, per-class setting, adapter defers?, expected]
      ["7.2.0", :always,  false, true],
      ["7.2.0", :never,   true,  false],
      ["7.2.0", :default, true,  true],   # :default consults the adapter — defers
      ["7.2.0", :default, false, false],  # :default consults the adapter — does not
      ["8.0.0", :always,  true,  true],
      ["8.0.0", :never,   true,  false],  # adapter consultation removed
      ["8.0.0", :default, true,  false],  # adapter consultation removed
      ["8.0.0", true,     false, true],
      ["8.0.0", false,    true,  false],
      ["8.1.0", true,     false, true],
      ["8.1.0", false,    true,  false],
      ["8.1.0", nil,      true,  false],
      ["8.1.0", :always,  false, true],   # truthiness: legacy symbols all defer
      ["8.1.0", :never,   false, true],   # truthiness footgun
      ["8.1.0", :default, false, true]    # truthiness footgun
    ]

    cases.each do |version, setting, adapter_defers, expected|
      job_class = fake_job_class(setting)
      adapter = fake_adapter(adapter_defers)
      actual = GoodPipeline::ExecutionConfiguration.enqueue_deferred?(
        job_class, adapter: adapter, active_job_version: Gem::Version.new(version)
      )

      assert_equal expected, actual,
                   "Rails #{version}, setting #{setting.inspect}, adapter #{adapter_defers}: expected #{expected}"
    end
  end

  private

  def assert_boot_rejects_async_without_polling(listen_notify, interval)
    with_configuration_override(:enable_listen_notify, listen_notify) do
      with_configuration_override(:poll_interval, interval) do
        error = assert_raises(GoodPipeline::ConfigurationError) do
          GoodPipeline.validate_good_job_configuration!
        end

        assert_match(/poll_interval > 0/, error.message)
        assert_match(%r{LISTEN/NOTIFY alone cannot recover}, error.message)
      end
    end
  end

  def assert_async_step_rejected_before_insert(listen_notify, interval) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    with_configuration_override(:enable_listen_notify, listen_notify) do
      with_configuration_override(:poll_interval, interval) do
        pipeline = create_pipeline(on_failure_strategy: "continue")
        pipeline.update_columns(status: "running")
        step = build_step(
          pipeline,
          key: "async_#{listen_notify}_#{interval}",
          job_class: "TestExecutionModeGuard::AsyncOverrideJob"
        )

        GoodPipeline::Coordinator.try_enqueue_step(step.id)

        assert_equal "failed", step.reload.coordination_status
        assert_match(/poll_interval > 0/, step.error_message)
        assert_equal 0, GoodJob::Job.where(job_class: "TestExecutionModeGuard::AsyncOverrideJob").count
        assert_equal 0, step_batch_count([step])
      end
    end
  end

  def assert_callback_dispatch_skipped(adapter) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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

  def effective_async_adapter
    GoodJob::Adapter.new(execution_mode: :external).tap do |adapter|
      adapter.define_singleton_method(:execute_async?) { true }
    end
  end

  def with_enqueue_deferral_setting(job_class, setting)
    original = job_class.enqueue_after_transaction_commit
    job_class.enqueue_after_transaction_commit = setting
    yield
  ensure
    job_class.enqueue_after_transaction_commit = original
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
