# frozen_string_literal: true

module GoodPipeline
  class Runner
    def self.call(pipeline_instance)
      new(pipeline_instance).call
    end

    def initialize(pipeline_instance)
      @pipeline = pipeline_instance
    end

    def call # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      pipeline_record = nil
      step_records = {}

      PipelineRecord.transaction do # rubocop:disable Metrics/BlockLength
        pipeline_record = PipelineRecord.create!(
          type: @pipeline.class.name,
          params: @pipeline.params,
          status: "pending",
          on_failure_strategy: @pipeline.failure_strategy.to_s
        )

        @pipeline.step_definitions.each do |step_definition|
          step_records[step_definition.key] = StepRecord.create!(
            pipeline: pipeline_record,
            key: step_definition.key.to_s,
            job_class: step_definition.job_class.name,
            params: step_definition.params,
            on_failure_strategy: step_definition.failure_strategy&.to_s,
            queue: step_definition.queue,
            priority: step_definition.priority
          )

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

        pipeline_record.transition_to!(:running)
      end

      @pipeline.root_steps.each do |step_definition|
        Coordinator.try_enqueue_step(step_records[step_definition.key].id)
      end

      pipeline_record
    end
  end
end
