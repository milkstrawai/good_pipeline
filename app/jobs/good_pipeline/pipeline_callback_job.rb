# frozen_string_literal: true

module GoodPipeline
  class PipelineCallbackJob < ActiveJob::Base
    def perform(pipeline_id, terminal_status)
      pipeline_record = GoodPipeline::PipelineRecord.find(pipeline_id)
      context = pipeline_record.type.constantize.for_callback(pipeline_record)

      callback = context.on_complete_callback
      context.send(callback) if callback

      case terminal_status
      when "succeeded"
        callback = context.on_success_callback
        context.send(callback) if callback
      when "failed", "halted"
        callback = context.on_failure_callback
        context.send(callback) if callback
      end
    end
  end
end
