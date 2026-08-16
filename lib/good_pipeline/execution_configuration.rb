# frozen_string_literal: true

module GoodPipeline
  # Validates the effective Active Job/GoodJob behavior used by pipeline work.
  # Boot validation permits a non-GoodJob global adapter because an application
  # may not enqueue pipeline work in that process; enqueue-boundary validation
  # is strict and rejects it before any coordination records are handed off.
  class ExecutionConfiguration
    RAILS_8_0 = Gem::Version.new("8.0")
    RAILS_8_1 = Gem::Version.new("8.1")

    class << self
      def validate_boot!
        unless GoodJob.preserve_job_records == true
          raise ConfigurationError, "GoodPipeline requires GoodJob.preserve_job_records = true"
        end

        adapter = ActiveJob::Base.queue_adapter
        return unless adapter.is_a?(GoodJob::Adapter)

        validate_good_job_adapter!(ActiveJob::Base, adapter)
      end

      def validate_enqueue!(job_class)
        adapter = job_class.queue_adapter

        unless adapter.is_a?(GoodJob::Adapter)
          raise ConfigurationError,
                "#{job_class} uses #{adapter.class}; GoodPipeline requires a GoodJob adapter — " \
                "other adapters bypass batch coordination entirely"
        end

        validate_good_job_adapter!(job_class, adapter)
      end

      # Mirrors the actual Active Job implementation for each supported Rails
      # line. Rails 7.2 delegates its default case to the adapter, Rails 8.0
      # handles the legacy symbols itself, and Rails 8.1 uses plain truthiness.
      # The version argument is injectable so the full compatibility table can
      # be tested under every appraisal without loading three Rails versions in
      # one process.
      def enqueue_deferred?(job_class, adapter:, active_job_version: ActiveJob.gem_version)
        setting = enqueue_after_transaction_commit_setting(job_class)
        version = Gem::Version.new(active_job_version.to_s)

        return truthy?(setting) if version >= RAILS_8_1
        return rails_8_0_enqueue_deferred?(setting) if version >= RAILS_8_0

        rails_7_2_enqueue_deferred?(setting, adapter)
      end

      private

      def validate_good_job_adapter!(job_class, adapter)
        validate_not_inline!(job_class, adapter)
        validate_async_polling!(job_class, adapter)
        validate_immediate_enqueue!(job_class, adapter)
      end

      def validate_not_inline!(job_class, adapter)
        return unless adapter.execute_inline?

        raise ConfigurationError,
              "#{job_class} uses GoodJob's :inline execution mode, which GoodPipeline does not support"
      end

      def validate_async_polling!(job_class, adapter)
        return unless adapter.execute_async? && GoodJob.configuration.poll_interval.to_i <= 0

        raise ConfigurationError,
              "#{job_class} executes GoodJob jobs in process, but GoodPipeline requires polling with " \
              "poll_interval > 0. A transactionally enqueued job can wake the local worker before " \
              "its outer transaction commits; when that worker is created, GoodJob suppresses NOTIFY, " \
              "so LISTEN/NOTIFY alone cannot recover the missed wakeup."
      end

      def validate_immediate_enqueue!(job_class, adapter)
        return unless enqueue_deferred?(job_class, adapter: adapter)

        raise ConfigurationError,
              "#{job_class} effectively defers enqueue until after commit; GoodPipeline requires immediate " \
              "database insertion so coordination state and durable handoffs share the caller's transaction"
      end

      def enqueue_after_transaction_commit_setting(job_class)
        return job_class.enqueue_after_transaction_commit if job_class.respond_to?(:enqueue_after_transaction_commit)

        :default
      end

      def rails_8_0_enqueue_deferred?(setting)
        case setting
        when :always then true
        when :never, :default then false
        else truthy?(setting)
        end
      end

      def rails_7_2_enqueue_deferred?(setting, adapter)
        case setting
        when :always then true
        when :never then false
        else adapter.respond_to?(:enqueue_after_transaction_commit?) && adapter.enqueue_after_transaction_commit?
        end
      end

      def truthy?(value)
        value ? true : false
      end
    end
  end
end
