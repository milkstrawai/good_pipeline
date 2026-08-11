# frozen_string_literal: true

module GoodPipeline
  module Dashboard
    # Batch-loads GoodJob timestamps for a collection of steps (or job ids).
    # Missing GoodJob rows are intentionally absent from the returned hash;
    # this is the normal retention-gap case.
    class StepTimings
      def self.call(steps_or_ids, **)
        new(steps_or_ids, **).call
      end

      class << self
        alias fetch call
      end

      def initialize(steps_or_ids, job_model: nil)
        @steps_or_ids = steps_or_ids
        @job_model = job_model
      end

      def call
        ids = job_ids
        return {} if ids.empty?

        job_model.where(id: ids).pluck(:id, :performed_at, :finished_at).to_h do |id, performed_at, finished_at|
          [id, [performed_at, finished_at].freeze]
        end
      end

      alias fetch call

      private

      def job_ids
        Array(@steps_or_ids).filter_map do |step_or_id|
          if step_or_id.respond_to?(:good_job_id)
            step_or_id.good_job_id
          else
            step_or_id
          end
        end.uniq
      end

      def job_model
        @job_model ||= GoodJob::Job
      end
    end
  end
end
