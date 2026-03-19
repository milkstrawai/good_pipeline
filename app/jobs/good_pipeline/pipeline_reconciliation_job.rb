# frozen_string_literal: true

module GoodPipeline
  class PipelineReconciliationJob < ActiveJob::Base
    def perform(batch, _context)
      pipeline = GoodPipeline::PipelineRecord.find(batch.properties[:pipeline_id])
      GoodPipeline::Coordinator.recompute_pipeline_status(pipeline)
    end
  end
end
