# frozen_string_literal: true

module GoodPipeline
  class Runner
    def self.call(pipeline_instance, start: true)
      new(pipeline_instance).call(start: start)
    end

    def initialize(pipeline_instance)
      @pipeline = pipeline_instance
    end

    def call(start: true) # rubocop:disable Metrics/MethodLength
      pipeline_id = SecureRandom.uuid
      pipeline_record = nil
      step_id_by_key = {}

      PipelineRecord.transaction do
        batch = create_pipeline_batch(pipeline_id)
        pipeline_record = create_pipeline_record(pipeline_id, batch.id, start: start)
        step_id_by_key = insert_steps(pipeline_record)
        insert_dependencies(pipeline_record, step_id_by_key)
      end

      enqueue_root_steps(step_id_by_key) if start

      pipeline_record
    end

    private

    def create_pipeline_batch(pipeline_id)
      batch = GoodJob::Batch.new
      batch.on_finish = "GoodPipeline::PipelineReconciliationJob"
      batch.properties = { pipeline_id: pipeline_id }
      batch.save
      batch
    end

    def create_pipeline_record(pipeline_id, batch_id, start:)
      PipelineRecord.create!(
        id: pipeline_id,
        type: @pipeline.class.name,
        params: @pipeline.params,
        status: start ? :running : :pending,
        on_failure_strategy: @pipeline.failure_strategy.to_s,
        good_job_batch_id: batch_id
      )
    end

    def insert_steps(pipeline_record) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      step_rows = @pipeline.step_definitions.map do |step_definition|
        {
          pipeline_id: pipeline_record.id,
          key: step_definition.key.to_s,
          job_class: resolve_job_class(step_definition),
          params: step_definition.params,
          on_failure_strategy: step_definition.failure_strategy&.to_s,
          enqueue_options: step_definition.enqueue_options,
          branch: build_branch_hash(step_definition),
          pending_upstream_count: step_definition.dependencies.size
        }
      end

      result = StepRecord.insert_all!(step_rows, returning: %w[id key])
      result.rows.each_with_object({}) { |(id, key), hash| hash[key.to_sym] = id }
    end

    def insert_dependencies(pipeline_record, step_id_by_key)
      dependency_rows = @pipeline.step_definitions.flat_map do |step_definition|
        step_definition.dependencies.map do |dependency_key|
          {
            pipeline_id: pipeline_record.id,
            step_id: step_id_by_key[step_definition.key],
            depends_on_step_id: step_id_by_key[dependency_key]
          }
        end
      end

      DependencyRecord.insert_all!(dependency_rows) if dependency_rows.any?
    end

    def enqueue_root_steps(step_id_by_key)
      root_step_ids = @pipeline.root_steps.map { |step_definition| step_id_by_key[step_definition.key] }
      Coordinator.bulk_enqueue_steps(root_step_ids)
    end

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
