# frozen_string_literal: true

module GoodPipeline
  class PipelinesController < ApplicationController # rubocop:disable Metrics/ClassLength
    PAGE_SIZE = 25

    SidebarEntry = Data.define(
      :type,
      :id,
      :on_failure_strategy,
      :run_count,
      :step_count,
      :has_branch,
      :large
    ) do
      alias_method :strategy, :on_failure_strategy
    end

    def index # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      @filters = Dashboard::FilterSet.from_params(params)
      @now = Time.current

      base_scope = apply_type_time_search(PipelineRecord.all)
      @status_counts = base_scope.group(:status).count
      @total = @filters.status == "all" ? @status_counts.values.sum : @status_counts.fetch(@filters.status, 0)

      last_page = [(@total.to_f / PAGE_SIZE).ceil, 1].max
      current_page = @filters.page.clamp(1, last_page)
      @page = { current: current_page, last: last_page, total: @total, per_page: PAGE_SIZE }

      list_scope = @filters.status == "all" ? base_scope : base_scope.where(status: @filters.status)
      @pipelines = list_scope.order(created_at: :desc, id: :desc)
                             .offset((current_page - 1) * PAGE_SIZE)
                             .limit(PAGE_SIZE)
                             .to_a

      load_page_steps
      load_expanded_row
      @sidebar_entries = load_sidebar_entries
      @pipeline_types = @sidebar_entries.map(&:type)
      @retention_seconds = GoodJob.configuration.cleanup_preserved_jobs_before_seconds_ago
      @kpis = Dashboard::KpiCalculator.new(pipeline_type: @filters.pipeline_type, now: @now).call
      @connection_info = Dashboard::ConnectionInfo.fetch
    end

    def definitions # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      @now = Time.current
      @pipelines = PipelineRecord
                   .select("DISTINCT ON (type) good_pipeline_pipelines.*")
                   .order(:type, created_at: :desc, id: :desc)
                   .to_a
      load_graph_records(@pipelines)
      @run_counts = PipelineRecord.group(:type).count
      @definition_runs = @run_counts
      @definition_stages_by_pipeline = @pipelines.to_h do |pipeline|
        stages = Dashboard::DefinitionStages.new(
          steps: @steps_by_pipeline.fetch(pipeline.id, []),
          dependencies: @dependencies_by_pipeline.fetch(pipeline.id, [])
        ).call
        [pipeline.id, stages]
      end
      @definition_stages = @definition_stages_by_pipeline
      @connection_info = Dashboard::ConnectionInfo.fetch
    end

    def show # rubocop:disable Metrics/MethodLength
      @now = Time.current
      @pipeline = PipelineRecord.find(params[:id])
      load_graph_records([@pipeline])
      @steps = @steps_by_pipeline.fetch(@pipeline.id, [])
      @dependencies = @dependencies_by_pipeline.fetch(@pipeline.id, [])
      @step_timings = Dashboard::StepTimings.new(@steps).call
      @stage_lanes = Dashboard::StageLanes.new(
        pipeline: @pipeline,
        steps: @steps,
        dependencies: @dependencies,
        timings: @step_timings,
        now: @now
      ).call
      load_chain_records
      @connection_info = Dashboard::ConnectionInfo.fetch
    end

    private

    def apply_type_time_search(scope)
      scope = scope.where(type: @filters.pipeline_type) if @filters.pipeline_type
      cutoff = @filters.time_cutoff(@now)
      scope = scope.where("created_at >= ?", cutoff) if cutoff
      return scope if @filters.query.blank?

      escaped = ActiveRecord::Base.sanitize_sql_like(@filters.query.strip)
      scope.where(
        "CAST(good_pipeline_pipelines.id AS text) ILIKE ? OR good_pipeline_pipelines.type ILIKE ?",
        "#{escaped}%",
        "%#{escaped}%"
      )
    end

    def load_page_steps
      page_ids = @pipelines.map(&:id)
      steps = StepRecord.where(pipeline_id: page_ids).order(:created_at, :id).to_a
      @steps_by_pipeline = steps.group_by(&:pipeline_id)
      attach_steps(@pipelines, @steps_by_pipeline)
    end

    def load_expanded_row # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      @expanded_pipeline = @pipelines.find { |pipeline| pipeline.id.to_s == @filters.expanded.to_s }
      return unless @expanded_pipeline

      @expanded_steps = @steps_by_pipeline.fetch(@expanded_pipeline.id, [])
      @expanded_dependencies = DependencyRecord.where(pipeline_id: @expanded_pipeline.id).order(:id).to_a
      hydrate_dependencies(@expanded_dependencies, @expanded_steps)
      @step_timings = Dashboard::StepTimings.new(@expanded_steps).call
      @stage_lanes = Dashboard::StageLanes.new(
        pipeline: @expanded_pipeline,
        steps: @expanded_steps,
        dependencies: @expanded_dependencies,
        timings: @step_timings,
        now: @now
      ).call
    end

    def load_sidebar_entries # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      latest = PipelineRecord
               .select(<<~SQL.squish)
                 DISTINCT ON (type)
                 type, id, on_failure_strategy,
                 COUNT(*) OVER (PARTITION BY type) AS run_count
               SQL
               .order(:type, created_at: :desc, id: :desc)
               .to_a

      ids = latest.map(&:id)
      quoted_branch_class = StepRecord.connection.quote(GoodPipeline::BRANCH_JOB_CLASS)
      metadata = StepRecord.where(pipeline_id: ids)
                           .group(:pipeline_id)
                           .pluck(
                             :pipeline_id,
                             Arel.sql("COUNT(*)"),
                             Arel.sql("BOOL_OR(job_class = #{quoted_branch_class})")
                           )
                           .to_h { |pipeline_id, count, has_branch| [pipeline_id, [count.to_i, has_branch]] }

      latest.map do |pipeline|
        step_count, has_branch = metadata.fetch(pipeline.id, [0, false])
        SidebarEntry.new(
          type: pipeline.type,
          id: pipeline.id,
          on_failure_strategy: pipeline.on_failure_strategy,
          run_count: pipeline.attributes.fetch("run_count").to_i,
          step_count: step_count,
          has_branch: has_branch,
          large: step_count > 60
        )
      end
    end

    def load_graph_records(pipelines) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      pipeline_ids = pipelines.map(&:id)
      steps = StepRecord.where(pipeline_id: pipeline_ids).order(:created_at, :id).to_a
      dependencies = DependencyRecord.where(pipeline_id: pipeline_ids).order(:id).to_a

      @steps_by_pipeline = steps.group_by(&:pipeline_id)
      @dependencies_by_pipeline = dependencies.group_by(&:pipeline_id)
      attach_steps(pipelines, @steps_by_pipeline)

      pipelines.each do |pipeline|
        pipeline_dependencies = @dependencies_by_pipeline.fetch(pipeline.id, [])
        hydrate_dependencies(pipeline_dependencies, @steps_by_pipeline.fetch(pipeline.id, []))
        association = pipeline.association(:dependencies)
        association.target = pipeline_dependencies
        association.loaded!
      end
    end

    def attach_steps(pipelines, steps_by_pipeline)
      pipelines.each do |pipeline|
        association = pipeline.association(:steps)
        association.target = steps_by_pipeline.fetch(pipeline.id, [])
        association.loaded!
      end
    end

    def hydrate_dependencies(dependencies, steps)
      by_id = steps.index_by(&:id)
      dependencies.each do |dependency|
        step_association = dependency.association(:step)
        step_association.target = by_id[dependency.step_id]
        step_association.loaded!
        upstream_association = dependency.association(:depends_on_step)
        upstream_association.target = by_id[dependency.depends_on_step_id]
        upstream_association.loaded!
      end
    end

    def load_chain_records # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      chains = ChainRecord.where(upstream_pipeline_id: @pipeline.id)
                          .or(ChainRecord.where(downstream_pipeline_id: @pipeline.id))
                          .to_a
      other_ids = chains.flat_map { |chain| [chain.upstream_pipeline_id, chain.downstream_pipeline_id] }
                        .uniq
                        .excluding(@pipeline.id)
      related = PipelineRecord.where(id: other_ids).index_by(&:id)

      @upstream_pipelines = chains.filter_map do |chain|
        related[chain.upstream_pipeline_id] if chain.downstream_pipeline_id == @pipeline.id
      end
      @downstream_pipelines = chains.filter_map do |chain|
        related[chain.downstream_pipeline_id] if chain.upstream_pipeline_id == @pipeline.id
      end

      upstream = @pipeline.association(:upstream_pipelines)
      upstream.target = @upstream_pipelines
      upstream.loaded!
      downstream = @pipeline.association(:downstream_pipelines)
      downstream.target = @downstream_pipelines
      downstream.loaded!
    end
  end
end
