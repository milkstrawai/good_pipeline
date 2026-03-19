# frozen_string_literal: true

class CreateGoodPipelineTables < ActiveRecord::Migration[8.1]
  def change
    # Uncomment for Postgres v12 or earlier to enable gen_random_uuid() support
    # enable_extension 'pgcrypto'

    create_table :good_pipeline_pipelines, id: :uuid do |t|
      t.string :type, null: false
      t.jsonb :params, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.boolean :halt_triggered, null: false, default: false
      t.uuid :good_job_batch_id
      t.string :on_failure_strategy, null: false, default: "halt"
      t.datetime :callbacks_dispatched_at

      t.timestamps
    end

    create_table :good_pipeline_steps, id: :uuid do |t|
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

    add_index :good_pipeline_steps, %i[pipeline_id key], unique: true

    create_table :good_pipeline_dependencies do |t|
      t.references :pipeline, null: false, foreign_key: { to_table: :good_pipeline_pipelines }, type: :uuid
      t.references :step, null: false, foreign_key: { to_table: :good_pipeline_steps }, type: :uuid
      t.references :depends_on_step, null: false, foreign_key: { to_table: :good_pipeline_steps }, type: :uuid
    end

    create_table :good_pipeline_chains, id: :uuid do |t|
      t.references :upstream_pipeline, null: false, foreign_key: { to_table: :good_pipeline_pipelines }, type: :uuid
      t.references :downstream_pipeline, null: false, foreign_key: { to_table: :good_pipeline_pipelines }, type: :uuid
    end
  end
end
