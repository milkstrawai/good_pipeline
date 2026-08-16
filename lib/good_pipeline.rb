# frozen_string_literal: true

require_relative "good_pipeline/version"
require_relative "good_pipeline/constants"
require_relative "good_pipeline/errors"
require_relative "good_pipeline/step_definition"
require_relative "good_pipeline/branch_builder"
require_relative "good_pipeline/cycle_detector"
require_relative "good_pipeline/graph_validator"
require_relative "good_pipeline/dashboard"
require_relative "good_pipeline/pipeline"
require_relative "good_pipeline/failure_metadata"
require_relative "good_pipeline/branch_resolver"
require_relative "good_pipeline/coordinator"
require_relative "good_pipeline/chain_coordinator"
require_relative "good_pipeline/runner"
require_relative "good_pipeline/haltable"
require_relative "good_pipeline/chain"
require_relative "good_pipeline/engine" if defined?(Rails::Engine)

module GoodPipeline
  DEFAULT_COORDINATION_QUEUE_NAME = "good_pipeline_coordination"
  DEFAULT_CALLBACK_QUEUE_NAME = "good_pipeline_callbacks"

  class << self
    attr_writer :coordination_queue_name, :callback_queue_name

    def coordination_queue_name
      @coordination_queue_name || DEFAULT_COORDINATION_QUEUE_NAME
    end

    def callback_queue_name
      @callback_queue_name || DEFAULT_CALLBACK_QUEUE_NAME
    end
  end

  def self.run(*pipeline_configs)
    pipeline_records = pipeline_configs.map do |config|
      pipeline_class, pipeline_params = extract_pipeline_config(config)
      instance = pipeline_class.build(**pipeline_params)
      Runner.call(instance)
    end

    Chain.new(pipeline_records)
  end

  # Internal: parses [PipelineClass, { with: { ... } }] config format.
  def self.extract_pipeline_config(config)
    [config[0], config.fetch(1, {}).fetch(:with, {})]
  end

  # Raised at boot for global misconfigurations under which coordination cannot
  # work at all. Per-job-class adapter overrides and post-boot changes are
  # caught at each enqueue boundary by the coordinator's adapter guard.
  def self.validate_good_job_configuration! # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    unless GoodJob.preserve_job_records == true
      raise ConfigurationError, "GoodPipeline requires GoodJob.preserve_job_records = true"
    end

    if GoodJob.configuration.enqueue_after_transaction_commit
      raise ConfigurationError,
            "GoodPipeline does not support GoodJob's enqueue_after_transaction_commit: deferring the " \
            "enqueue past commit loses batch context, so step completion callbacks would never fire."
    end

    # Both remaining checks read the *effective adapter*, never GoodJob's
    # configured symbol. GoodJob reports execution_mode :inline for any app that
    # leaves it unset under Rails.env.test?, but that value is only ever consulted
    # by a GoodJob adapter — an app on the Active Job :test adapter is not
    # executing anything inline, and rejecting it here would abort boot for a mode
    # it is not running. The adapter's own predicates are the truth, and a
    # non-GoodJob adapter is caught precisely at the enqueue boundary by
    # Coordinator.ensure_supported_adapter!.
    adapter = ActiveJob::Base.queue_adapter
    return unless adapter.is_a?(GoodJob::Adapter)

    if adapter.execute_inline?
      raise ConfigurationError,
            "GoodPipeline does not support GoodJob's :inline execution mode: a step's job runs before " \
            "its coordination row is stamped, so halt_pipeline! is silently discarded, a failing step " \
            "aborts its siblings, and steps enqueued with a delay (including retry_on backoff) never " \
            "run at all. For tests, use execution_mode :external and drain with GoodJob.perform_inline " \
            "(as the demo app does)."
    end

    # :async and :async_server behave as :external outside a webserver, so this is
    # inherently per-process — the webserver needs a wakeup channel, a rake task
    # running the same configuration does not. A job enqueued inside a transaction
    # can wake the in-process worker before commit; that thread finds nothing, and
    # because it was created GoodJob suppresses the NOTIFY. Recovery then needs
    # either the poller (disabled for any interval <= 0) or LISTEN/NOTIFY, whose
    # deliveries are transactional and therefore land after commit. Only the
    # absence of *both* is unrecoverable.
    return unless adapter.execute_async? &&
                  GoodJob.configuration.poll_interval.to_i <= 0 &&
                  !GoodJob.configuration.enable_listen_notify

    raise ConfigurationError,
          "GoodPipeline requires a wakeup channel when GoodJob executes jobs in-process: enable " \
          "polling (poll_interval > 0) or LISTEN/NOTIFY (enable_listen_notify), otherwise a job " \
          "enqueued inside a transaction can wake the async worker before commit — which finds " \
          "nothing and suppresses the NOTIFY — with nothing left to recover it."
  end

  def self.cleanup_preserved_pipelines(older_than:)
    PipelineRecord.transaction do
      # Candidates are selected under lock with both predicates re-applied so
      # they are authoritative at deletion time: a pipeline that left a terminal
      # status after being identified no longer matches, and a row held by a
      # concurrent claim (e.g. a settlement in flight) is skipped, deferring its
      # pruning to the next sweep.
      pipeline_ids = PipelineRecord.where(status: PipelineRecord::TERMINAL_STATUSES)
                                   .where("updated_at < ?", older_than)
                                   .lock("FOR UPDATE SKIP LOCKED")
                                   .pluck(:id)
      next if pipeline_ids.empty?

      delete_pipeline_graph(pipeline_ids)
    end
  end

  def self.delete_pipeline_graph(pipeline_ids)
    DependencyRecord.where(pipeline_id: pipeline_ids).delete_all
    StepRecord.where(pipeline_id: pipeline_ids).delete_all
    ChainRecord.where(upstream_pipeline_id: pipeline_ids)
               .or(ChainRecord.where(downstream_pipeline_id: pipeline_ids))
               .delete_all
    PipelineRecord.where(id: pipeline_ids).delete_all
  end
  private_class_method :delete_pipeline_graph
end
