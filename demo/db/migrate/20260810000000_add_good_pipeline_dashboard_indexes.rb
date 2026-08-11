# frozen_string_literal: true

class AddGoodPipelineDashboardIndexes < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :good_pipeline_pipelines, %i[type created_at id],
              order: { created_at: :desc, id: :desc },
              name: :index_gp_pipelines_on_type_created_at_id,
              algorithm: :concurrently, if_not_exists: true
    add_index :good_pipeline_pipelines, %i[status created_at id],
              order: { created_at: :desc, id: :desc },
              name: :index_gp_pipelines_on_status_created_at_id,
              algorithm: :concurrently, if_not_exists: true
    add_index :good_pipeline_pipelines, %i[created_at id],
              order: { created_at: :desc, id: :desc },
              name: :index_gp_pipelines_on_created_at_id,
              algorithm: :concurrently, if_not_exists: true
  end
end
