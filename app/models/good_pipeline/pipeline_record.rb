# frozen_string_literal: true

module GoodPipeline
  # This model intentionally has no AR callbacks or validations. Status transitions
  # use update_columns throughout the coordinator layer. If you need lifecycle hooks,
  # ensure all update_columns call sites are updated accordingly.
  class PipelineRecord < ActiveRecord::Base
    self.table_name = "good_pipeline_pipelines"
    self.inheritance_column = nil

    TERMINAL_STATUSES = %w[succeeded failed halted skipped].freeze

    VALID_TRANSITIONS = {
      "pending" => %w[running skipped],
      "running" => %w[succeeded failed halted]
    }.freeze

    enum :status, {
      pending: "pending",
      running: "running",
      succeeded: "succeeded",
      failed: "failed",
      halted: "halted",
      skipped: "skipped"
    }

    enum :on_failure_strategy, { halt: "halt", continue: "continue", ignore: "ignore" }

    has_many :steps,
             class_name: "GoodPipeline::StepRecord",
             foreign_key: :pipeline_id,
             inverse_of: :pipeline,
             dependent: :destroy

    has_many :dependencies,
             class_name: "GoodPipeline::DependencyRecord",
             foreign_key: :pipeline_id,
             inverse_of: :pipeline,
             dependent: :delete_all

    has_many :downstream_chains,
             class_name: "GoodPipeline::ChainRecord",
             foreign_key: :upstream_pipeline_id,
             inverse_of: :upstream_pipeline,
             dependent: :delete_all

    has_many :downstream_pipelines,
             through: :downstream_chains,
             source: :downstream_pipeline

    has_many :upstream_chains,
             class_name: "GoodPipeline::ChainRecord",
             foreign_key: :downstream_pipeline_id,
             inverse_of: :downstream_pipeline,
             dependent: :delete_all

    has_many :upstream_pipelines,
             through: :upstream_chains,
             source: :upstream_pipeline

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    # Operator cancellation is recorded as a timestamp rather than a status so
    # that a canceled pipeline still reports `halted` to every existing filter,
    # badge and KPI query. `canceled_at` is what tells the two apart.
    def canceled?
      canceled_at.present?
    end

    # Cancellation drains rather than kills: steps already handed to GoodJob run
    # to completion, so a canceled pipeline stays `running` until they report back.
    def canceling?
      canceled? && !terminal?
    end

    def cancelable?
      running? && !canceled?
    end

    def transition_to!(new_status)
      new_status = new_status.to_s
      allowed = VALID_TRANSITIONS.fetch(status, [])

      unless allowed.include?(new_status)
        raise InvalidTransition, "cannot transition pipeline from '#{status}' to '#{new_status}'"
      end

      update_columns(status: new_status, updated_at: Time.current)
    end
  end
end
