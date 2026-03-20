# frozen_string_literal: true

module GoodPipeline
  class StepRecord < ActiveRecord::Base
    self.table_name = "good_pipeline_steps"

    TERMINAL_COORDINATION_STATUSES = %w[succeeded failed skipped].freeze

    VALID_COORDINATION_TRANSITIONS = {
      "pending" => %w[enqueued skipped],
      "enqueued" => %w[succeeded failed]
    }.freeze

    enum :coordination_status, {
      pending: "pending",
      enqueued: "enqueued",
      succeeded: "succeeded",
      failed: "failed",
      skipped: "skipped"
    }

    enum :on_failure_strategy, { halt: "halt", continue: "continue", ignore: "ignore" }

    belongs_to :pipeline,
               class_name: "GoodPipeline::PipelineRecord",
               foreign_key: :pipeline_id,
               inverse_of: :steps

    has_many :upstream_dependencies,
             class_name: "GoodPipeline::DependencyRecord",
             foreign_key: :step_id,
             inverse_of: :step,
             dependent: :delete_all

    has_many :upstream_steps,
             through: :upstream_dependencies,
             source: :depends_on_step

    has_many :downstream_dependencies,
             class_name: "GoodPipeline::DependencyRecord",
             foreign_key: :depends_on_step_id,
             inverse_of: :depends_on_step,
             dependent: :delete_all

    has_many :downstream_steps,
             through: :downstream_dependencies,
             source: :step

    def duration
      return nil unless good_job_id

      good_job = GoodJob::Job.find_by(id: good_job_id)
      return nil unless good_job&.performed_at && good_job.finished_at

      good_job.finished_at - good_job.performed_at
    end

    def terminal_coordination_status?
      TERMINAL_COORDINATION_STATUSES.include?(coordination_status)
    end

    def transition_coordination_status_to!(new_status)
      new_status = new_status.to_s
      allowed = VALID_COORDINATION_TRANSITIONS.fetch(coordination_status, [])

      unless allowed.include?(new_status)
        raise InvalidTransition,
              "cannot transition step '#{key}' coordination_status from '#{coordination_status}' to '#{new_status}'"
      end

      update!(coordination_status: new_status)
    end
  end
end
