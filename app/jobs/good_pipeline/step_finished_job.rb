# frozen_string_literal: true

module GoodPipeline
  class StepFinishedJob < ActiveJob::Base
    def perform(batch, _context)
      step = GoodPipeline::StepRecord.find(batch.properties[:step_id])
      GoodPipeline::Coordinator.complete_step(step, succeeded: batch.succeeded?)
    end
  end
end
