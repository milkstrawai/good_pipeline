# frozen_string_literal: true

module GoodPipeline
  class Engine < ::Rails::Engine
    engine_name "good_pipeline"
    isolate_namespace GoodPipeline

    # Registered after GoodJob's own rails_config initializer so our
    # after_initialize callback runs after GoodJob has applied
    # `config.good_job.*` — validating at on_load(:active_job) read defaults
    # and let an application-configured broken setting boot.
    initializer "good_pipeline.check_good_job_config", after: "good_job.rails_config" do |app|
      app.config.after_initialize do
        GoodPipeline.validate_good_job_configuration!
      end
    end

    initializer "good_pipeline.haltable" do
      ActiveSupport.on_load(:active_job) do
        include GoodPipeline::Haltable
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
