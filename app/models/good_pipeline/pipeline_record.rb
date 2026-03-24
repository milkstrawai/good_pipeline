# frozen_string_literal: true

module GoodPipeline
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

    def transition_to!(new_status)
      new_status = new_status.to_s
      allowed = VALID_TRANSITIONS.fetch(status, [])

      unless allowed.include?(new_status)
        raise InvalidTransition, "cannot transition pipeline from '#{status}' to '#{new_status}'"
      end

      update!(status: new_status)
    end
  end
end
