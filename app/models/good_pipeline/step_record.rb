# frozen_string_literal: true

module GoodPipeline
  # This model intentionally has no AR callbacks or validations. Status transitions
  # use update_columns throughout the coordinator layer. If you need lifecycle hooks,
  # ensure all update_columns call sites are updated accordingly.
  class StepRecord < ActiveRecord::Base
    self.table_name = "good_pipeline_steps"

    TERMINAL_COORDINATION_STATUSES = %w[succeeded failed skipped skipped_by_branch halted].freeze

    VALID_COORDINATION_TRANSITIONS = {
      "pending" => %w[enqueued skipped skipped_by_branch succeeded failed halted],
      "enqueued" => %w[succeeded failed halted]
    }.freeze

    enum :coordination_status, {
      pending: "pending",
      enqueued: "enqueued",
      succeeded: "succeeded",
      failed: "failed",
      skipped: "skipped",
      skipped_by_branch: "skipped_by_branch",
      halted: "halted"
    }

    enum :on_failure_strategy, { halt: "halt", continue: "continue", ignore: "ignore" }

    store_accessor :branch, :decides, :branch_result, :branch_key, :branch_arm, :empty_arms

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

    def branch_step? = job_class == GoodPipeline::BRANCH_JOB_CLASS
    def branch_arm_step? = branch_arm.present?

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

      update_columns(coordination_status: new_status, updated_at: Time.current)
    end
  end
end
