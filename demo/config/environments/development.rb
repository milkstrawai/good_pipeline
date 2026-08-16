# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :log
  config.good_job.execution_mode = :async
  # GoodJob defaults a development async mode to poll_interval -1, which disables
  # the poller. LISTEN/NOTIFY alone would still carry the dev server (see the
  # boot check in lib/good_pipeline.rb), but a live poller is the durable wakeup
  # and costs nothing here.
  config.good_job.poll_interval = 1
end
