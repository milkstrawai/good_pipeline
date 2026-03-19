# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/autorun"

ActiveJob::Base.logger = Logger.new(nil)

module ActiveSupport
  class TestCase
    self.use_transactional_tests = false

    teardown do
      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end

    private

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

    def build_step(pipeline, key:, dependencies: [], on_failure_strategy: nil)
      step = create_step(pipeline, key: key, on_failure_strategy: on_failure_strategy)
      dependencies.each do |dependency_step|
        GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: step, depends_on_step: dependency_step)
      end
      step
    end
  end
end
