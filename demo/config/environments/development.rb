# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :log
  config.good_job.execution_mode = :async
  # GoodJob defaults a development async mode to poll_interval -1, which disables
  # the poller. GoodPipeline requires positive polling because a local worker can
  # wake before an enqueue transaction commits and suppress the corresponding
  # NOTIFY; LISTEN/NOTIFY alone cannot recover that miss.
  config.good_job.poll_interval = 10
end
