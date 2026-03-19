# frozen_string_literal: true

require "test_helper"
require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  host: "localhost",
  database: "good_pipeline_test",
  username: "postgres",
  password: "postgres"
)

ActiveRecord::Schema.define do
  enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

  create_table :good_pipeline_pipelines, id: :uuid, if_not_exists: true do |t|
    t.string :type, null: false
    t.jsonb :params, null: false, default: {}
    t.string :status, null: false, default: "pending"
    t.boolean :halt_triggered, null: false, default: false
    t.uuid :good_job_batch_id
    t.string :on_failure_strategy, null: false, default: "halt"
    t.datetime :callbacks_dispatched_at

    t.timestamps
  end

  create_table :good_pipeline_steps, id: :uuid, if_not_exists: true do |t|
    t.references :pipeline, null: false, foreign_key: { to_table: :good_pipeline_pipelines }, type: :uuid
    t.string :key, null: false
    t.string :job_class, null: false
    t.jsonb :params, null: false, default: {}
    t.string :coordination_status, null: false, default: "pending"
    t.string :observed_status
    t.string :on_failure_strategy
    t.string :queue
    t.integer :priority
    t.uuid :good_job_batch_id
    t.uuid :good_job_id
    t.integer :attempts
    t.string :error_class
    t.text :error_message
    t.datetime :started_at
    t.datetime :finished_at

    t.timestamps
  end

  unless index_exists?(:good_pipeline_steps, %i[pipeline_id key])
    add_index :good_pipeline_steps, %i[pipeline_id key], unique: true
  end

  create_table :good_pipeline_dependencies, if_not_exists: true do |t|
    t.references :pipeline, null: false, foreign_key: { to_table: :good_pipeline_pipelines }, type: :uuid
    t.references :step, null: false, foreign_key: { to_table: :good_pipeline_steps }, type: :uuid
    t.references :depends_on_step, null: false, foreign_key: { to_table: :good_pipeline_steps }, type: :uuid
  end

  create_table :good_pipeline_chains, id: :uuid, if_not_exists: true do |t|
    t.references :upstream_pipeline, null: false, foreign_key: { to_table: :good_pipeline_pipelines }, type: :uuid
    t.references :downstream_pipeline, null: false, foreign_key: { to_table: :good_pipeline_pipelines }, type: :uuid
  end
end

require_relative "../app/models/good_pipeline/pipeline_record"
require_relative "../app/models/good_pipeline/step_record"
require_relative "../app/models/good_pipeline/dependency_record"
require_relative "../app/models/good_pipeline/chain_record"

module ActiveRecordTestCase
  def setup
    super
    GoodPipeline::ChainRecord.delete_all
    GoodPipeline::DependencyRecord.delete_all
    GoodPipeline::StepRecord.delete_all
    GoodPipeline::PipelineRecord.delete_all
  end

  private

  def create_pipeline(**attrs)
    GoodPipeline::PipelineRecord.create!(
      { type: "TestPipeline" }.merge(attrs)
    )
  end

  def create_step(pipeline, key: "step_a", job_class: "TestJob", **attrs)
    GoodPipeline::StepRecord.create!(
      { pipeline: pipeline, key: key, job_class: job_class }.merge(attrs)
    )
  end
end
