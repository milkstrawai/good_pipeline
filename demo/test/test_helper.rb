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
      Rails.cache.clear
      ActiveRecord::Base.connection.truncate_tables(*ActiveRecord::Base.connection.tables)
    end

    private

    def count_dashboard_queries(&block) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      queries = []
      ActiveRecord::Base.connection.clear_query_cache
      callback = lambda do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        next if payload[:name].to_s == "SCHEMA"
        next if payload[:cached] || payload[:name].to_s == "CACHE"
        next if sql.match?(/\A\s*(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i)
        next if sql.match?(/SHOW server_version_num/i)

        queries << sql
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        ActiveRecord::Base.uncached(&block)
      end
      queries
    end

    def rails_promise(&block)
      Concurrent::Promises.future do
        Rails.application.executor.wrap(&block)
      end
    end

    def perform_enqueued_jobs_inline
      GoodJob.perform_inline
    end

    def run_pipeline_to_completion(pipeline_record, timeout: 15)
      deadline = Time.current + timeout
      loop do
        perform_enqueued_jobs_inline
        pipeline_record.reload
        return pipeline_record if pipeline_record.terminal?

        if Time.current > deadline
          raise "Pipeline did not reach terminal state within #{timeout}s (status: #{pipeline_record.status})"
        end

        sleep 0.05
      end
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

    # Reports a step outcome the way StepFinishedJob does: through the batch
    # claim. Assigns a batch id when the fixture never enqueued for real.
    def complete_step_for(step, succeeded:)
      step.reload
      step.update_columns(good_job_batch_id: SecureRandom.uuid) if step.good_job_batch_id.nil?
      GoodPipeline::Coordinator.complete_step(
        step_id: step.id,
        batch_id: step.good_job_batch_id,
        succeeded: succeeded
      )
    end

    def build_step(pipeline, key:, dependencies: [], on_failure_strategy: nil, **attributes)
      step = create_step(pipeline, key: key, on_failure_strategy: on_failure_strategy, **attributes)
      dependencies.each do |dependency_step|
        GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: step, depends_on_step: dependency_step)
      end
      step.update_column(:pending_upstream_count, dependencies.size)
      step
    end
  end
end
