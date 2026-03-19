# frozen_string_literal: true

module GoodPipeline
  class DependencyRecord < ActiveRecord::Base
    self.table_name = "good_pipeline_dependencies"
    self.record_timestamps = false

    belongs_to :pipeline,
               class_name: "GoodPipeline::PipelineRecord",
               foreign_key: :pipeline_id,
               inverse_of: :dependencies

    belongs_to :step,
               class_name: "GoodPipeline::StepRecord",
               foreign_key: :step_id,
               inverse_of: :upstream_dependencies

    belongs_to :depends_on_step,
               class_name: "GoodPipeline::StepRecord",
               foreign_key: :depends_on_step_id,
               inverse_of: :downstream_dependencies
  end
end
