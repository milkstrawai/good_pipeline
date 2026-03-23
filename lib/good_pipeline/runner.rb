# frozen_string_literal: true

module GoodPipeline
  class Runner
    def self.call(pipeline_instance, start: true)
      new(pipeline_instance).call(start: start)
    end

    def initialize(pipeline_instance)
      @pipeline = pipeline_instance
    end

    def call(start: true) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      pipeline_record = nil
      step_records = {}

      PipelineRecord.transaction do # rubocop:disable Metrics/BlockLength
        pipeline_record = PipelineRecord.create!(
          type: @pipeline.class.name,
          params: @pipeline.params,
          status: :pending,
          on_failure_strategy: @pipeline.failure_strategy.to_s
        )

        # Two passes: create all step records first, then dependencies.
        # Branch steps may appear after their dependents in step_definitions.
        @pipeline.step_definitions.each do |step_definition|
          step_records[step_definition.key] = StepRecord.create!(
            pipeline: pipeline_record,
            key: step_definition.key.to_s,
            job_class: resolve_job_class(step_definition),
            params: step_definition.params,
            on_failure_strategy: step_definition.failure_strategy&.to_s,
            enqueue_options: step_definition.enqueue_options,
            branch: build_branch_hash(step_definition)
          )
        end

        @pipeline.step_definitions.each do |step_definition| # rubocop:disable Style/CombinableLoops
          step_definition.dependencies.each do |dependency_key|
            DependencyRecord.create!(
              pipeline: pipeline_record,
              step: step_records[step_definition.key],
              depends_on_step: step_records[dependency_key]
            )
          end
        end

        pipeline_batch = GoodJob::Batch.new
        pipeline_batch.on_finish = "GoodPipeline::PipelineReconciliationJob"
        pipeline_batch.properties = { pipeline_id: pipeline_record.id }
        pipeline_batch.save
        pipeline_record.update_column(:good_job_batch_id, pipeline_batch.id)

        pipeline_record.transition_to!(:running) if start
      end

      if start
        @pipeline.root_steps.each do |step_definition|
          Coordinator.try_enqueue_step(step_records[step_definition.key].id)
        end
      end

      pipeline_record
    end

    private

    def resolve_job_class(step_definition)
      step_definition.job_class.is_a?(String) ? step_definition.job_class : step_definition.job_class.name
    end

    def build_branch_hash(step_definition) # rubocop:disable Metrics/AbcSize
      hash = {}
      hash["decides"] = step_definition.decides.to_s if step_definition.decides
      hash["empty_arms"] = step_definition.empty_arms.map(&:to_s) if step_definition.empty_arms.any?
      hash["branch_key"] = step_definition.branch_key.to_s if step_definition.branch_key
      hash["branch_arm"] = step_definition.branch_arm.to_s if step_definition.branch_arm
      hash
    end
  end
end
