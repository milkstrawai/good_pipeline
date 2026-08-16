# frozen_string_literal: true

class AddGoodPipelineCancellation < ActiveRecord::Migration[7.2]
  def change
    add_column :good_pipeline_pipelines, :canceled_at, :datetime, if_not_exists: true
  end
end
