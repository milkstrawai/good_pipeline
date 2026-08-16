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
end
