# frozen_string_literal: true

module GoodPipeline
  class PipelineCallbackJob < ActiveJob::Base
    CALLBACK_STATUSES = PipelineRecord::TERMINAL_STATUSES

    def perform(pipeline_id, terminal_status) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      unless CALLBACK_STATUSES.include?(terminal_status)
        raise ArgumentError, "invalid terminal_status '#{terminal_status}'"
      end

      pipeline_record = GoodPipeline::PipelineRecord.find(pipeline_id)
      pipeline = pipeline_record.type.constantize.reconstruct(pipeline_record)

      errors = []

      invoke_callback(pipeline, pipeline.on_complete_callback, errors)

      case terminal_status
      when PipelineRecord.statuses[:succeeded]
        invoke_callback(pipeline, pipeline.on_success_callback, errors)
      when PipelineRecord.statuses[:failed], PipelineRecord.statuses[:halted]
        invoke_callback(pipeline, pipeline.on_failure_callback, errors)
      when PipelineRecord.statuses[:skipped], PipelineRecord.statuses[:canceled]
        # Skipped and canceled pipelines only trigger on_complete (already called above)
      end

      raise_callback_errors(errors) if errors.any?
    end

    private

    def invoke_callback(pipeline, callback, errors)
      return unless callback

      pipeline.send(callback)
    rescue StandardError => error
      errors << error
    end

    def raise_callback_errors(errors)
      return if errors.empty?

      primary = errors.first
      if errors.size > 1
        suppressed = errors[1..].map { |error| "#{error.class}: #{error.message}" }.join("; ")
        raise primary, "#{primary.message} (suppressed #{errors.size - 1} additional error(s): #{suppressed})"
      end
      raise primary
    end
  end
end
