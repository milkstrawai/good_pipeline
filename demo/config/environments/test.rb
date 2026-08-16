# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = true if config.respond_to?(:action_controller)
  config.cache_store = :memory_store
  config.active_support.deprecation = :stderr
  config.action_controller.allow_forgery_protection = false
  config.good_job.execution_mode = :external

  # Boot-regression hook: proves the validation initializer runs after GoodJob
  # applies Rails configuration. Only the config.good_job path exercises that
  # ordering — an env var GoodJob reads directly would be visible to an
  # early-running validator too.
  config.good_job.preserve_job_records = false if ENV["GP_BREAK_PRESERVE_JOB_RECORDS"]

  # Boot-regression hooks for effective execution validation. Rails 7.2's
  # load_defaults sets ActiveJob::Base to :default, which consults this adapter
  # setting; Rails 8.0+ leaves the class setting false, so the same raw GoodJob
  # value has no effect there.
  config.good_job.enqueue_after_transaction_commit = true if ENV["GP_ENABLE_ADAPTER_ENQUEUE_DEFERRAL"]

  if ENV["GP_BREAK_ASYNC_POLLING"]
    config.good_job.execution_mode = :async_all
    config.good_job.poll_interval = -1
    config.good_job.enable_listen_notify = true
  end
end
