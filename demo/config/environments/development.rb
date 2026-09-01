# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :log
  config.good_job.execution_mode = :async
end

# The demo is a local development application; expose its pipeline controls.
GoodPipeline.dashboard_mutations_enabled = true
