# frozen_string_literal: true

module GoodPipeline
  module Haltable
    def halt_pipeline!
      step = GoodPipeline::StepRecord.find_by(good_job_id: provider_job_id)
      step&.update_columns(halt_requested: true, updated_at: Time.current)
    end
  end
end
