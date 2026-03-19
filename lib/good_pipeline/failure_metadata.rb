# frozen_string_literal: true

module GoodPipeline
  class FailureMetadata
    Result = Struct.new(:error_class, :error_message, :attempts)

    def self.extract(step)
      good_job = GoodJob::Job.find_by(id: step.good_job_id)
      return Result.new(error_class: nil, error_message: nil, attempts: 0) unless good_job

      error_class, error_message = parse_error(good_job.error)

      Result.new(
        error_class: error_class,
        error_message: error_message,
        attempts: good_job.executions_count
      )
    end

    def self.parse_error(error_string)
      return [nil, nil] if error_string.blank?

      parts = error_string.split(GoodJob::Job::ERROR_MESSAGE_SEPARATOR, 2)
      [parts[0]&.strip, parts[1]&.strip]
    end

    private_class_method :parse_error
  end
end
