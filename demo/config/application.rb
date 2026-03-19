# frozen_string_literal: true

require_relative "boot"
require "rails/all"
require "good_job"
require "good_job/engine"
require "good_pipeline"
require "good_pipeline/engine"

Bundler.require(*Rails.groups)

module TestApp
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    config.active_job.queue_adapter = :good_job
  end
end
