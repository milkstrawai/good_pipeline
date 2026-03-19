# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/autorun"

ActiveJob::Base.logger = Logger.new(nil)

# Create attempt_trackers table for retry tests
ActiveRecord::Base.connection.create_table :attempt_trackers, if_not_exists: true do |t|
  t.string :key, null: false
  t.integer :count, default: 0, null: false
end

module ActiveSupport
  class TestCase
    self.use_transactional_tests = false

    teardown do
      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end

    private

    def rails_promise(&block)
      Concurrent::Promises.future do
        Rails.application.executor.wrap(&block)
      end
    end

    def perform_enqueued_jobs_inline
      GoodJob.perform_inline
    end

    def wait_until(timeout: 10, interval: 0.1)
      deadline = Time.current + timeout
      loop do
        return if yield

        raise "Timeout waiting for condition" if Time.current > deadline

        sleep interval
      end
    end

    def create_pipeline(**attributes)
      GoodPipeline::PipelineRecord.create!(
        { type: "TestPipeline" }.merge(attributes)
      )
    end

    def create_step(pipeline, key: "step_a", job_class: "DownloadJob", **attributes)
      GoodPipeline::StepRecord.create!(
        {
          pipeline: pipeline,
          key: key,
          job_class: job_class
        }.merge(attributes)
      )
    end

    def build_step(pipeline, key:, dependencies: [], on_failure_strategy: nil, **attributes)
      step = create_step(pipeline, key: key, on_failure_strategy: on_failure_strategy, **attributes)
      dependencies.each do |dependency_step|
        GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: step, depends_on_step: dependency_step)
      end
      step
    end
  end
end
