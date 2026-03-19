# frozen_string_literal: true

module GoodPipeline
  class PipelineCallbackJob < ActiveJob::Base
    CALLBACK_STATUSES = %w[succeeded failed halted].freeze

    def perform(pipeline_id, terminal_status) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      unless CALLBACK_STATUSES.include?(terminal_status)
        raise ArgumentError, "invalid terminal_status '#{terminal_status}'"
      end

      pipeline_record = GoodPipeline::PipelineRecord.find(pipeline_id)
      pipeline = pipeline_record.type.constantize.for_callback(pipeline_record)

      errors = []

      invoke_callback(pipeline, pipeline.on_complete_callback, errors)

      case terminal_status
      when PipelineRecord.statuses[:succeeded]
        invoke_callback(pipeline, pipeline.on_success_callback, errors)
      when PipelineRecord.statuses[:failed], PipelineRecord.statuses[:halted]
        invoke_callback(pipeline, pipeline.on_failure_callback, errors)
      end

      raise errors.first if errors.any?
    end

    private

    def invoke_callback(pipeline, callback, errors)
      return unless callback

      pipeline.send(callback)
    rescue StandardError => e
      errors << e
    end
  end
end
