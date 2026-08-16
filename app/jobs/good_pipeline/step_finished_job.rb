# frozen_string_literal: true

module GoodPipeline
  class StepFinishedJob < ActiveJob::Base
    def perform(batch, _context)
      GoodPipeline::Coordinator.complete_step(
        step_id: batch.properties[:step_id],
        batch_id: batch.id,
        succeeded: batch.succeeded?
      )
    end
  end
end
