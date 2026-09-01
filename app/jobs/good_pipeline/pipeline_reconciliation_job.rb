# frozen_string_literal: true

module GoodPipeline
  class PipelineReconciliationJob < ActiveJob::Base
    def perform(batch, _context)
      GoodPipeline::Coordinator.recompute_pipeline_status(batch.properties[:pipeline_id])
    end
  end
end
