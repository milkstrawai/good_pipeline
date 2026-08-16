# frozen_string_literal: true

require "test_helper"

# The positive case justifying async support: work enqueued inside an open
# transaction gets no usable in-process wakeup — GoodJob's batch enqueue either
# wakes the worker before commit and then suppresses the NOTIFY, or (with
# LISTEN/NOTIFY disabled) issues no wakeup at all — and the poller is what
# recovers it after commit. Async modes are "eventually live through polling",
# and these prove the recovery actually happens.
#
# A real async server starts its capsule at boot; these tests model that by
# starting it explicitly (force: true keeps them order-independent, since a
# shutdown capsule is otherwise not restartable within the process).
class TestAsyncPollingRecovery < ActiveSupport::TestCase
  # LISTEN/NOTIFY disabled: GoodJob's batch enqueue skips its notification
  # phase entirely — no pre-commit wakeup, no NOTIFY — so the poller is
  # provably the only recovery path. This is the configuration the boot check
  # requires poll_interval > 0 for.
  def test_transactionally_enqueued_work_recovers_via_the_poller_without_listen_notify
    pipeline, root = running_pipeline_with_root

    with_configuration_override(:enable_listen_notify, false) do
      with_configuration_override(:execution_mode, :async_all) do
        with_configuration_override(:poll_interval, 1) do
          GoodJob.capsule.start(force: true)

          ActiveRecord::Base.transaction do
            GoodPipeline::Coordinator.bulk_enqueue_steps([root.id])
          end

          wait_until(timeout: 15) { root.reload.coordination_status == "succeeded" }
          wait_until(timeout: 15) { pipeline.reload.terminal? }
        end
      end
    end

    assert_equal "succeeded", root.reload.coordination_status
    assert_equal "succeeded", pipeline.reload.status
  ensure
    GoodJob.shutdown
  end

  # LISTEN/NOTIFY enabled: the enqueue wakes the in-process worker before
  # commit — that thread finds nothing — and because it was created the NOTIFY
  # is suppressed, so the poller is again what recovers the work.
  def test_suppressed_notify_wakeup_miss_recovers_via_the_poller
    pipeline, root = running_pipeline_with_root

    with_configuration_override(:execution_mode, :async_all) do
      with_configuration_override(:poll_interval, 1) do
        GoodJob.capsule.start(force: true)

        ActiveRecord::Base.transaction do
          GoodPipeline::Coordinator.bulk_enqueue_steps([root.id])
        end

        wait_until(timeout: 15) { root.reload.coordination_status == "succeeded" }
        wait_until(timeout: 15) { pipeline.reload.terminal? }
      end
    end

    assert_equal "succeeded", root.reload.coordination_status
    assert_equal "succeeded", pipeline.reload.status
  ensure
    GoodJob.shutdown
  end

  private

  def running_pipeline_with_root
    pipeline = create_pipeline(on_failure_strategy: "halt")
    pipeline.update_columns(status: "running")
    [pipeline, build_step(pipeline, key: "a")]
  end

  def with_configuration_override(method, value)
    GoodJob.configuration.define_singleton_method(method) { value }
    yield
  ensure
    GoodJob.configuration.singleton_class.remove_method(method)
  end
end
