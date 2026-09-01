# frozen_string_literal: true

require "test_helper"
require "active_support/testing/time_helpers"

# Integration coverage deliberately verifies several parts of each complete
# dashboard response in one request.
# rubocop:disable Minitest/MultipleAssertions
module GoodPipeline
  class DashboardTest < ActionDispatch::IntegrationTest # rubocop:disable Metrics/ClassLength
    include ActiveSupport::Testing::TimeHelpers

    setup do
      GoodPipeline.dashboard_mutations_enabled = true
    end

    teardown do
      GoodPipeline.dashboard_mutations_enabled = nil
    end

    test "index renders the isolated dark dashboard and versioned assets" do
      execution = create_execution(type: "VideoProcessingPipeline", status: "succeeded")
      create_step(execution, key: "download", coordination_status: "succeeded")

      get "/good_pipeline"

      assert_response :success
      assert_includes response.body, %(data-gp-theme="dark")
      assert_includes response.body, %(class="gp-app gp-app--dashboard")
      assert_includes response.body, %(id="gp-kpi")
      assert_includes response.body, %(id="gp-filters")
      assert_select ".gp-status-filter-scroll > .gp-segment[role=group][aria-label='Status filter']", count: 1
      assert_includes response.body, %(id="gp-table")
      assert_no_match(/data-href/, response.body)
      asset_href = response.body[%r{href="([^"]*/frontend/static/0-5-0/dashboard\.css)"}, 1]

      assert asset_href&.end_with?("/frontend/static/0-5-0/dashboard.css")
      refute_includes response.body, "style.css"
      refute_includes response.body, "<script>"

      assert_dashboard_css(asset_href)

      get "/good_pipeline/frontend/static/0-5-0/dashboard.js"

      assert_response :success
      assert_includes response.media_type, "javascript"
      assert_includes response.body, "AbortController"
      assert_includes response.body, "form[data-gp-confirm]"
      assert_includes response.body, "window.confirm"
    end

    test "status time type and search filters compose" do
      now = Time.utc(2026, 8, 10, 12)
      wanted = create_execution(
        type: "VideoProcessingPipeline", status: "failed", created_at: now - 2.hours
      )
      create_step(wanted, key: "download", coordination_status: "failed")
      create_execution(type: "VideoProcessingPipeline", status: "succeeded", created_at: now - 2.hours)
      create_execution(type: "OtherPipeline", status: "failed", created_at: now - 2.hours)
      create_execution(type: "VideoProcessingPipeline", status: "failed", created_at: now - 3.days)

      travel_to(now) do
        get "/good_pipeline", params: {
          pipeline_type: "VideoProcessingPipeline",
          status: "failed",
          time: "24h",
          q: wanted.id.to_s.first(8)
        }
      end

      assert_response :success
      assert_includes response.body, wanted.id.to_s.first(8)
      assert_includes response.body, "Video Processing"
      assert_includes response.body, "failed"
      assert_match(/filtered rows.*?1/m, response.body)
    end

    test "status segment counts ignore only the selected status" do
      2.times { create_execution(type: "CountPipeline", status: "failed") }
      create_execution(type: "CountPipeline", status: "succeeded")
      create_execution(type: "OtherPipeline", status: "running")

      get "/good_pipeline", params: { pipeline_type: "CountPipeline", status: "failed" }

      assert_response :success
      assert_includes response.body, %(data-gp-segment-value="all" data-gp-status-count="3")
      assert_includes response.body, %(data-gp-segment-value="failed" data-gp-status-count="2")
      assert_includes response.body, %(data-gp-segment-value="succeeded" data-gp-status-count="1")
      assert_match(/filtered rows.*?2/m, response.body)
    end

    test "pagination clamps malformed and out of range pages" do
      28.times do |index|
        create_execution(type: "PagePipeline", status: "succeeded", created_at: Time.current - index.minutes)
      end

      %w[0 -3 abc 99999].each do |page|
        get "/good_pipeline", params: { page: page }

        assert_response :success
        assert_match(%r{page <span class="mono">(?:1|2)</span> / <span class="mono">2</span>}, response.body)
      end

      get "/good_pipeline", params: { q: "no-such-execution", page: 99_999 }

      assert_response :success
      assert_match(%r{page <span class="mono">1</span> / <span class="mono">1</span>}, response.body)
      assert_includes response.body, "no executions match these filters"
    end

    test "unknown expanded id is ignored and a loaded execution expands" do
      execution = create_execution(type: "ExpandablePipeline", status: "running")
      step = create_step(execution, key: "work", coordination_status: "enqueued")
      attach_good_job(step, performed_at: Time.current - 10.seconds, finished_at: nil)

      get "/good_pipeline", params: { expanded: SecureRandom.uuid }

      assert_response :success
      refute_includes response.body, "gp-row-detail-inner"

      get "/good_pipeline", params: { expanded: execution.id }

      assert_response :success
      assert_includes response.body, "gp-row-detail-inner"
      assert_includes response.body, "is-running"
      assert_includes response.body, %(colspan="7")
      assert_match(/disabled(?:="disabled")? title="not yet implemented"/, response.body)
    end

    test "canonical pipeline_type parameter scopes executions" do
      create_execution(type: "AlphaPipeline", status: "succeeded")
      create_execution(type: "BetaPipeline", status: "succeeded")

      get "/good_pipeline", params: { pipeline_type: "AlphaPipeline" }

      assert_response :success
      assert_includes response.body, "Alpha"
      refute_match(/gp-execution-name">Beta</, response.body)
      assert_includes response.body, "pipeline_type=AlphaPipeline"
    end

    test "show keeps GoodJob links error text and safe Mermaid transport" do
      execution = create_execution(type: "UnsafePipeline", status: "failed")
      first = create_step(
        execution,
        key: %(end_node"; x),
        coordination_status: "failed",
        error_class: "DemoError",
        error_message: "unsafe input failed"
      )
      attach_good_job(first, performed_at: Time.current - 4.seconds, finished_at: Time.current)

      get "/good_pipeline/pipelines/#{execution.id}"

      assert_response :success
      assert_includes response.body, "DemoError: unsafe input failed"
      assert_includes response.body, "/good_job/jobs/#{first.good_job_id}"
      assert_includes response.body, "data-graph="
      assert_includes response.body, "n0"
      assert_includes response.body, "#quot;"
      refute_includes response.body, "raw mermaid"
    end

    test "cancel forms render with CSRF and confirmation on show and expanded row" do
      running = create_execution(type: "CancelableRunningPipeline", status: "running")
      create_step(running, key: "work", coordination_status: "enqueued")
      pending = create_execution(type: "CancelablePendingPipeline", status: "pending")
      create_step(pending, key: "work", coordination_status: "pending")

      assert_equal "/good_pipeline/pipelines/#{running.id}/cancel",
                   GoodPipeline::Engine.routes.url_helpers.cancel_pipeline_path(running)

      with_forgery_protection do
        get "/good_pipeline/pipelines/#{running.id}"
      end

      assert_response :success
      assert_cancel_form(running)
      assert_select "button[disabled]", text: "re-run pipeline", count: 1

      with_forgery_protection do
        get "/good_pipeline", params: { expanded: pending.id }
      end

      assert_response :success
      assert_cancel_form(pending)
      assert_select %(.gp-actions a[href="/good_pipeline/pipelines/#{pending.id}"]),
                    text: "detail page + dag ↗", count: 1
    end

    test "read-only mode hides cancel controls and rejects direct posts" do
      GoodPipeline.dashboard_mutations_enabled = nil
      execution = create_execution(type: "ReadOnlyPipeline", status: "running")
      step = create_step(execution, key: "work", coordination_status: "enqueued")

      get "/good_pipeline/pipelines/#{execution.id}"

      assert_response :success
      assert_select "form.gp-action-form", count: 0
      assert_select "button", text: "cancel requested", count: 0
      assert_select "button", text: /re-run pipeline|retry failed step/, count: 0

      get "/good_pipeline", params: { expanded: execution.id }

      assert_response :success
      assert_select "form.gp-action-form", count: 0
      assert_select "button", text: /re-run pipeline|retry failed step/, count: 0

      post "/good_pipeline/pipelines/#{execution.id}/cancel", headers: dashboard_csrf_headers

      assert_response :forbidden
      assert_equal "running", execution.reload.status
      assert_equal "enqueued", step.reload.coordination_status
    end

    test "canceling and canceled statuses render without another cancel submission" do
      canceling = create_execution(type: "CancelingPipeline", status: "canceling")
      create_step(canceling, key: "already_drained", coordination_status: "canceled")
      canceled = create_execution(type: "CanceledPipeline", status: "canceled")

      get "/good_pipeline/pipelines/#{canceling.id}"

      assert_response :success
      assert_select ".gp-status--canceling", text: /canceling/, minimum: 1
      assert_select "button[disabled]", text: "cancel requested", count: 1
      assert_select "form.gp-action-form", count: 0
      assert_select ".gp-status--canceled", text: /canceled/, minimum: 1
      assert_includes response.body, ":::canceled"

      get "/good_pipeline/pipelines/#{canceled.id}"

      assert_response :success
      assert_select ".gp-detail-header .gp-status--canceled", text: /canceled/, count: 1
      assert_select "form.gp-action-form", count: 0
      assert_select "button.gp-action--danger[disabled]", text: "cancel pipeline", count: 1

      get "/good_pipeline", params: { status: "canceled" }

      assert_response :success
      assert_select %(tr[data-id="#{canceled.id}"] .gp-status--canceled), text: /canceled/, count: 1
      assert_select '[data-gp-segment-value="canceled"].is-active', count: 1
    end

    test "cancel posts through the coordinator and redirects back with a notice" do
      execution = create_execution(type: "CancelablePipeline", status: "running")
      create_step(execution, key: "work", coordination_status: "enqueued")
      referer = "http://www.example.com/good_pipeline?expanded=#{execution.id}"
      headers = dashboard_csrf_headers.merge("HTTP_REFERER" => referer)

      post "/good_pipeline/pipelines/#{execution.id}/cancel", headers: headers

      assert_response :see_other
      assert_redirected_to referer
      assert_equal "Pipeline cancellation requested.", flash[:notice]
      assert_nil flash[:alert]
      assert_equal "canceling", execution.reload.status
    end

    test "cancel without a referrer falls back to detail and reports immediate cancellation" do
      execution = create_execution(type: "TestPipeline", status: "pending")

      post "/good_pipeline/pipelines/#{execution.id}/cancel", headers: dashboard_csrf_headers

      assert_response :see_other
      assert_redirected_to "/good_pipeline/pipelines/#{execution.id}"
      assert_equal "Pipeline canceled.", flash[:notice]
      assert_equal "canceled", execution.reload.status

      follow_redirect!

      assert_response :success
      assert_select ".gp-flash.gp-flash--notice[role=status]", text: "Pipeline canceled.", count: 1
      assert_select ".gp-flash--alert", count: 0
    end

    test "repeated cancel request remains an idempotent HTML success" do
      execution = create_execution(type: "AlreadyCancelingPipeline", status: "canceling")
      create_step(execution, key: "draining", coordination_status: "enqueued")

      post "/good_pipeline/pipelines/#{execution.id}/cancel", headers: dashboard_csrf_headers

      assert_response :see_other
      assert_redirected_to "/good_pipeline/pipelines/#{execution.id}"
      assert_equal "Pipeline cancellation requested.", flash[:notice]
      assert_nil flash[:alert]
    end

    test "cancel conflict redirects safely and renders only an alert flash" do
      execution = create_execution(type: "CompletedPipeline", status: "succeeded")
      referer = "http://www.example.com/good_pipeline/pipelines/#{execution.id}"
      headers = dashboard_csrf_headers.merge("HTTP_REFERER" => referer)

      post "/good_pipeline/pipelines/#{execution.id}/cancel", headers: headers

      assert_response :see_other
      assert_redirected_to referer
      assert_equal "Pipeline is already succeeded and cannot be canceled.", flash[:alert]
      assert_nil flash[:notice]

      follow_redirect!

      assert_response :success
      assert_select ".gp-flash.gp-flash--alert[role=alert]",
                    text: "Pipeline is already succeeded and cannot be canceled.", count: 1
      assert_select ".gp-flash--notice", count: 0
    end

    test "GET cannot invoke the cancel member endpoint" do
      execution = create_execution(type: "NonMutatingPipeline", status: "running")

      get "/good_pipeline/pipelines/#{execution.id}/cancel"

      assert_response :not_found
      assert_equal "running", execution.reload.status
    end

    test "show defaults pipelines over sixty steps to stages while retaining the full graph payload" do
      execution = create_execution(type: "ExtraLargePipeline", status: "succeeded")
      steps = insert_steps(execution, count: 61, prefix: "node")
      insert_dependencies(execution, steps.each_cons(2).to_a)

      get "/good_pipeline/pipelines/#{execution.id}"

      assert_response :success
      assert_select ".gp-stage-panel:not([hidden])", count: 1
      assert_select ".gp-graph-panel[hidden]", count: 1
      assert_select "[data-gp-graph-toggle]", text: "render full graph", count: 1
      assert_select ".gp-diagram-container[data-graph]", count: 1
      assert_includes response.body, "n60"
    end

    test "show disables an overflowing dense graph and omits its Mermaid payload" do
      execution = create_execution(type: "DenseFanoutPipeline", status: "succeeded")
      steps = insert_steps(execution, count: 46, prefix: "node")
      edges = steps.each_with_index.flat_map do |downstream, index|
        steps.first(index).map { |upstream| [upstream, downstream] }
      end
      insert_dependencies(execution, edges)

      get "/good_pipeline/pipelines/#{execution.id}"

      assert_response :success
      assert_equal 1_035, edges.length
      assert_select ".gp-stage-panel:not([hidden])", count: 1
      assert_select ".gp-diagram-container[data-graph]", count: 0
      assert_select "button[disabled]", text: "render full graph", count: 1
      assert_includes response.body, "1,035 edges exceeds Mermaid’s 1,000-edge safety limit"
    end

    test "show renders upstream and downstream chain chips" do
      upstream = create_execution(type: "UpstreamPipeline", status: "succeeded")
      execution = create_execution(type: "MiddlePipeline", status: "running")
      downstream = create_execution(type: "DownstreamPipeline", status: "pending")
      [upstream, execution, downstream].each { |pipeline| create_step(pipeline) }
      ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: execution)
      ChainRecord.create!(upstream_pipeline: execution, downstream_pipeline: downstream)

      get "/good_pipeline/pipelines/#{execution.id}"

      assert_response :success
      assert_select ".gp-chain-chip", count: 2
      assert_select %(.gp-chain-chip[href="/good_pipeline/pipelines/#{upstream.id}"]), count: 1
      assert_select %(.gp-chain-chip[href="/good_pipeline/pipelines/#{downstream.id}"]), count: 1
      assert_includes response.body, "Upstream"
      assert_includes response.body, "Downstream"
    end

    test "definitions render run counts and declared dependencies" do
      first_run = create_execution(type: "DefinitionPipeline", status: "succeeded", created_at: 2.hours.ago)
      add_linear_steps(first_run, %w[first second])
      latest = create_execution(type: "DefinitionPipeline", status: "succeeded", created_at: 1.hour.ago)
      add_linear_steps(latest, %w[first second terminal])

      get "/good_pipeline/pipelines/definitions"

      assert_response :success
      assert_includes response.body, "gp-app--definitions"
      assert_includes response.body, "Definition"
      assert_match(%r{runs</b>\s*2}, response.body)
      assert_includes response.body, "after: first"
      assert_includes response.body, "data-graph="
    end

    test "theme endpoint validates values persists the cookie and is mount aware" do
      get "/good_pipeline"
      csrf_token = response.body[/name="csrf-token" content="([^"]+)"/, 1]
      headers = { "X-CSRF-Token" => csrf_token }

      patch "/good_pipeline/theme", params: { theme: "light" }, headers: headers, as: :json

      assert_response :no_content
      assert_includes Array(response.headers.fetch("Set-Cookie")).join("; "), "good_pipeline_theme=light"

      patch "/good_pipeline/theme", params: { theme: "neon" }, headers: headers, as: :json

      assert_response :unprocessable_entity

      get "/good_pipeline", headers: { "Cookie" => "good_pipeline_theme=neon" }

      assert_response :success
      assert_includes response.body, %(data-gp-theme="dark")
      assert_includes response.body, %(name="good-pipeline-theme-url" content="/good_pipeline/theme")
    end

    test "index query budget is seven cold and five warm" do
      now = Time.utc(2026, 8, 10, 12)
      execution = create_execution(type: "BudgetPipeline", status: "succeeded", created_at: now - 1.hour)
      create_step(execution, key: "one", coordination_status: "succeeded")

      travel_to(now) do
        Rails.cache.clear
        cold = count_dashboard_queries { get "/good_pipeline" }

        assert_response :success
        warm = count_dashboard_queries { get "/good_pipeline" }

        assert_response :success

        assert_equal 7, cold.length, cold.join("\n---\n")
        assert_equal 5, warm.length, warm.join("\n---\n")
      end
    end

    test "expanding adds only dependency and GoodJob timing queries" do
      now = Time.utc(2026, 8, 10, 12)
      execution = create_execution(type: "BudgetPipeline", status: "running", created_at: now - 1.hour)
      first = create_step(execution, key: "first", coordination_status: "succeeded")
      second = create_step(execution, key: "second", coordination_status: "enqueued")
      DependencyRecord.create!(pipeline: execution, step: second, depends_on_step: first)
      attach_good_job(first, performed_at: now - 50.minutes, finished_at: now - 49.minutes)
      attach_good_job(second, performed_at: now - 1.minute, finished_at: nil)

      travel_to(now) do
        Rails.cache.clear
        count_dashboard_queries { get "/good_pipeline" }
        collapsed = count_dashboard_queries { get "/good_pipeline" }
        expanded = count_dashboard_queries { get "/good_pipeline", params: { expanded: execution.id } }

        assert_equal collapsed.length + 2, expanded.length, expanded.join("\n---\n")
      end
    end

    test "show query count is fixed across step counts with one optional chain lookup" do
      small = create_execution(type: "SmallQueryPipeline", status: "succeeded")
      insert_steps(small, count: 2, prefix: "small", with_good_jobs: true)
      large = create_execution(type: "LargeQueryPipeline", status: "succeeded")
      insert_steps(large, count: 18, prefix: "large", with_good_jobs: true)

      small_queries = count_dashboard_queries { get "/good_pipeline/pipelines/#{small.id}" }

      assert_response :success
      large_queries = count_dashboard_queries { get "/good_pipeline/pipelines/#{large.id}" }

      assert_response :success
      assert_equal small_queries.length, large_queries.length, large_queries.join("\n---\n")
      assert_equal 1, good_job_query_count(small_queries), small_queries.join("\n---\n")
      assert_equal 1, good_job_query_count(large_queries), large_queries.join("\n---\n")

      related = create_execution(type: "RelatedQueryPipeline", status: "succeeded")
      ChainRecord.create!(upstream_pipeline: related, downstream_pipeline: large)
      chained_queries = count_dashboard_queries { get "/good_pipeline/pipelines/#{large.id}" }

      assert_response :success
      # Chain rows are always loaded in one query. A populated chain permits
      # exactly one additional batch lookup for the related pipeline records.
      assert_equal large_queries.length + 1, chained_queries.length, chained_queries.join("\n---\n")
      assert_equal 1, good_job_query_count(chained_queries), chained_queries.join("\n---\n")
    end

    test "sidebar uses one latest execution query and one metadata query regardless of type count" do
      2.times do |index|
        execution = create_execution(type: "Sidebar#{index}Pipeline", status: "succeeded")
        create_step(execution)
      end

      first_queries = count_dashboard_queries { get "/good_pipeline" }

      assert_response :success
      assert_sidebar_query_pair(first_queries)

      8.times do |index|
        execution = create_execution(type: "MoreSidebar#{index}Pipeline", status: "succeeded")
        create_step(execution)
      end
      second_queries = count_dashboard_queries { get "/good_pipeline" }

      assert_response :success
      assert_sidebar_query_pair(second_queries)
    end

    test "committed dashboard index migration is rerunnable against existing indexes" do
      require Rails.root.join("db/migrate/20260810000000_add_good_pipeline_dashboard_indexes").to_s
      migration = AddGoodPipelineDashboardIndexes.new

      ActiveRecord::Migration.suppress_messages do
        2.times { migration.migrate(:up) }
      end

      names = ActiveRecord::Base.connection.indexes(:good_pipeline_pipelines).map(&:name)

      assert_equal 1, names.count("index_gp_pipelines_on_type_created_at_id")
      assert_equal 1, names.count("index_gp_pipelines_on_status_created_at_id")
      assert_equal 1, names.count("index_gp_pipelines_on_created_at_id")
    end

    private

    def assert_dashboard_css(asset_href)
      get asset_href

      assert_response :success
      assert_includes response.media_type, "css"
      assert_includes response.body, ".gp-status-filter-scroll"
      assert_match(/\.gp-flash\s*\{[^}]*box-sizing:border-box;/m, response.body)
    end

    def create_execution(type:, status:, created_at: Time.current - 5.minutes, duration: 1.minute, # rubocop:disable Metrics/MethodLength
                         strategy: "halt")
      execution = PipelineRecord.create!(
        type: type,
        status: status,
        params: { source: "test" },
        on_failure_strategy: strategy
      )
      execution.update_columns(
        created_at: created_at,
        updated_at: status == "running" ? created_at : created_at + duration
      )
      execution
    end

    def assert_cancel_form(execution)
      action = "/good_pipeline/pipelines/#{execution.id}/cancel"
      selector = %(form.gp-action-form[action="#{action}"][method="post"][data-gp-confirm])
      assert_select selector, count: 1 do
        assert_select "button.gp-action--danger", text: "cancel pipeline", count: 1
        assert_select 'input[name="authenticity_token"]', count: 1
      end
      assert_includes response.body, "Future DAG steps won&#39;t be scheduled"
      assert_includes response.body, "enqueued, scheduled, or retrying jobs will continue normally"
    end

    def dashboard_csrf_headers
      get "/good_pipeline"
      token = response.body[/name="csrf-token" content="([^"]+)"/, 1]
      { "X-CSRF-Token" => token }
    end

    def with_forgery_protection
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    def add_linear_steps(execution, keys) # rubocop:disable Metrics/MethodLength
      previous = nil
      keys.each_with_index do |key, index|
        current = create_step(
          execution,
          key: key,
          coordination_status: "succeeded",
          created_at: execution.created_at + index.seconds
        )
        DependencyRecord.create!(pipeline: execution, step: current, depends_on_step: previous) if previous
        previous = current
      end
    end

    def attach_good_job(step, performed_at:, finished_at:) # rubocop:disable Metrics/MethodLength
      job_id = SecureRandom.uuid
      scheduled_at = finished_at ? performed_at : Time.utc(2100, 1, 1)
      GoodJob::Job.create!(
        id: job_id,
        active_job_id: job_id,
        queue_name: "good_pipeline_dashboard_test",
        priority: 0,
        serialized_params: {
          "job_class" => step.job_class,
          "job_id" => job_id,
          "queue_name" => "good_pipeline_dashboard_test",
          "arguments" => [],
          "executions" => 0
        },
        scheduled_at: scheduled_at,
        performed_at: performed_at,
        finished_at: finished_at,
        job_class: step.job_class,
        executions_count: finished_at ? 1 : 0
      )
      step.update!(good_job_id: job_id)
      step
    end

    def insert_steps(execution, count:, prefix:, with_good_jobs: false) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      now = execution.created_at
      job_ids = Array.new(count) { SecureRandom.uuid }
      rows = Array.new(count) do |index|
        {
          id: SecureRandom.uuid,
          pipeline_id: execution.id,
          key: format("%<prefix>s_%<index>02d", prefix: prefix, index: index),
          job_class: "DashboardStepJob",
          coordination_status: "succeeded",
          good_job_id: with_good_jobs ? job_ids.fetch(index) : nil,
          created_at: now + index.seconds,
          updated_at: now + index.seconds
        }
      end
      StepRecord.insert_all!(rows)
      insert_good_jobs(job_ids, now:) if with_good_jobs
      StepRecord.where(id: rows.pluck(:id)).order(:created_at, :id).to_a
    end

    def insert_dependencies(execution, pairs)
      DependencyRecord.insert_all!(pairs.map do |upstream, downstream|
        {
          pipeline_id: execution.id,
          step_id: downstream.id,
          depends_on_step_id: upstream.id
        }
      end)
    end

    def insert_good_jobs(ids, now:) # rubocop:disable Metrics/MethodLength
      GoodJob::Job.insert_all!(ids.map do |id|
        {
          id: id,
          active_job_id: id,
          queue_name: "good_pipeline_dashboard_test",
          priority: 0,
          serialized_params: {
            "job_class" => "DashboardStepJob",
            "job_id" => id,
            "queue_name" => "good_pipeline_dashboard_test",
            "arguments" => [],
            "executions" => 1
          },
          scheduled_at: now,
          performed_at: now,
          finished_at: now + 1.second,
          job_class: "DashboardStepJob",
          executions_count: 1,
          created_at: now,
          updated_at: now + 1.second
        }
      end)
    end

    def good_job_query_count(queries)
      queries.count { |sql| sql.match?(/\bFROM\s+"good_jobs"/i) }
    end

    def assert_sidebar_query_pair(queries)
      latest = queries.count do |sql|
        sql.include?("DISTINCT ON (type)") && sql.include?("COUNT(*) OVER (PARTITION BY type)")
      end
      metadata = queries.count { |sql| sql.include?("BOOL_OR(job_class") }

      assert_equal 1, latest, queries.join("\n---\n")
      assert_equal 1, metadata, queries.join("\n---\n")
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
