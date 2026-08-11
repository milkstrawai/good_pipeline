# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = true if config.respond_to?(:action_controller)
  config.cache_store = :memory_store
  config.active_support.deprecation = :stderr
  config.good_job.execution_mode = :external
end
