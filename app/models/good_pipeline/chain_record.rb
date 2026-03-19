# frozen_string_literal: true

module GoodPipeline
  class ChainRecord < ActiveRecord::Base
    self.table_name = "good_pipeline_chains"
    self.record_timestamps = false

    belongs_to :upstream_pipeline,
               class_name: "GoodPipeline::PipelineRecord",
               foreign_key: :upstream_pipeline_id,
               inverse_of: :downstream_chains

    belongs_to :downstream_pipeline,
               class_name: "GoodPipeline::PipelineRecord",
               foreign_key: :downstream_pipeline_id,
               inverse_of: :upstream_chains
  end
end
