# frozen_string_literal: true

module GoodPipeline
  class PipelinesController < ApplicationController
    PAGE_SIZE = 25

    def index
      @status = params[:status].presence
      @pipeline_type = params[:pipeline_type].presence
      @pipeline_types = PipelineRecord.distinct.pluck(:type).sort
      counts_scope = @pipeline_type ? PipelineRecord.where(type: @pipeline_type) : PipelineRecord
      @status_counts = counts_scope.group(:status).count
      @total_count = @status_counts.values.sum
      load_pipelines
    end

    def definitions
      pipeline_types = PipelineRecord.distinct.pluck(:type).sort
      pipeline_ids = pipeline_types.filter_map do |type|
        PipelineRecord.where(type: type).order(created_at: :desc).pick(:id)
      end
      @pipelines = PipelineRecord.includes(steps: :upstream_steps, dependencies: %i[step depends_on_step])
                                 .where(id: pipeline_ids)
                                 .sort_by(&:type)
    end

    def show
      scope = PipelineRecord.includes(
        :upstream_pipelines, :downstream_pipelines,
        steps: :upstream_steps,
        dependencies: %i[step depends_on_step]
      )
      @pipeline = scope.find(params[:id])
    end

    private

    def load_pipelines
      scope = PipelineRecord.order(created_at: :desc, id: :desc)
      scope = scope.where(status: @status) if @status
      scope = scope.where(type: @pipeline_type) if @pipeline_type
      scope = apply_keyset_pagination(scope)
      records = scope.limit(PAGE_SIZE + 1).to_a
      @has_next_page = records.size > PAGE_SIZE
      @pipelines = records.first(PAGE_SIZE)
    end

    def apply_keyset_pagination(scope)
      return scope unless params[:after_created_at].present? && params[:after_id].present?

      scope.where(
        "(created_at, id) < (?, ?)",
        params[:after_created_at],
        params[:after_id]
      )
    end
  end
end
