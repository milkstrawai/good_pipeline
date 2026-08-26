# frozen_string_literal: true

module GoodPipeline
  class StepFinishedJob < ActiveJob::Base
    def perform(batch, _context)
      properties = batch.properties
      GoodPipeline::Coordinator.complete_step(
        properties[:step_id],
        pipeline_id: properties[:pipeline_id],
        succeeded: batch.succeeded?
      )
    end
  end
end
