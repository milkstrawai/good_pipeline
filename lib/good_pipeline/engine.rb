# frozen_string_literal: true

module GoodPipeline
  class Engine < ::Rails::Engine
    engine_name "good_pipeline"
    isolate_namespace GoodPipeline

    initializer "good_pipeline.check_good_job_config" do
      ActiveSupport.on_load(:active_job) do
        next if GoodJob.preserve_job_records == true

        raise GoodPipeline::ConfigurationError, "GoodPipeline requires GoodJob.preserve_job_records = true"
      end
    end

    initializer "good_pipeline.cleanup_hook" do
      ActiveSupport::Notifications.subscribe("cleanup_preserved_jobs.good_job") do |event|
        timestamp = event.payload[:timestamp]
        GoodPipeline.cleanup_preserved_pipelines(older_than: timestamp) if timestamp
      end
    end
  end
end
