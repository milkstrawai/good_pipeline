# frozen_string_literal: true

require "test_helper"

# Each integration example verifies the full mutation contract: response,
# persistence, and the source execution's unchanged history.
# rubocop:disable Minitest/MultipleAssertions
module GoodPipeline
  class DashboardRerunTest < ActionDispatch::IntegrationTest # rubocop:disable Metrics/ClassLength
    TERMINAL_STATUSES = %w[succeeded failed halted skipped canceled].freeze
    ACTIVE_STATUSES = %w[pending running canceling].freeze

    setup do
      GoodPipeline.dashboard_mutations_enabled = true
    end

    teardown do
      GoodPipeline.dashboard_mutations_enabled = nil
    end

    test "terminal pipelines render a confirmed rerun form with CSRF protection" do
      TERMINAL_STATUSES.each do |status|
        source = create_execution(type: "VideoProcessingPipeline", status: status, params: { video_id: status })

        with_forgery_protection { get "/good_pipeline/pipelines/#{source.id}" }

        assert_response :success
        assert_rerun_form(source)
      end
    end

    test "terminal pipelines render the rerun form in an expanded row" do
      source = create_execution(type: "TestPipeline", status: "succeeded")

      with_forgery_protection do
        get "/good_pipeline", params: { expanded: source.id }
      end

      assert_response :success
      assert_rerun_form(source)
    end

    test "active pipelines render a disabled rerun button" do
      ACTIVE_STATUSES.each do |status|
        source = create_execution(type: "TestPipeline", status: status)

        get "/good_pipeline/pipelines/#{source.id}"

        assert_response :success
        assert_select rerun_form_selector(source), count: 0
        assert_select "button.gp-action[disabled][title='available after the pipeline finishes']",
                      text: "re-run pipeline", count: 1
      end
    end

    test "rerun starts a fresh standalone execution from current code and stored params" do # rubocop:disable Metrics/BlockLength
      callback_time = 1.minute.ago
      source = create_execution(
        type: "VideoProcessingPipeline",
        status: "failed",
        params: { video_id: "video-123" },
        callbacks_dispatched_at: callback_time
      )
      historical_step = create_step(source, key: "removed_historical_step", coordination_status: "failed")
      upstream = create_execution(type: "TestPipeline", status: "succeeded")
      downstream = create_execution(type: "TestPipeline", status: "skipped")
      ChainRecord.create!(upstream_pipeline: upstream, downstream_pipeline: source)
      ChainRecord.create!(upstream_pipeline: source, downstream_pipeline: downstream)
      headers = dashboard_csrf_headers

      assert_difference -> { PipelineRecord.count }, 1 do
        post "/good_pipeline/pipelines/#{source.id}/rerun", headers: headers
      end

      rerun = PipelineRecord.where.not(id: [source.id, upstream.id, downstream.id]).sole

      assert_response :see_other
      assert_redirected_to "/good_pipeline/pipelines/#{rerun.id}"
      assert_equal "Pipeline re-run started.", flash[:notice]
      assert_equal "VideoProcessingPipeline", rerun.type
      assert_equal source.params, rerun.params
      assert_equal "running", rerun.status
      assert_nil rerun.callbacks_dispatched_at
      assert_equal %w[cleanup download publish thumbnail transcode], rerun.steps.order(:key).pluck(:key)
      assert_equal 5, rerun.dependencies.count
      assert_equal "enqueued", rerun.steps.find_by!(key: "download").coordination_status
      assert_equal 0, chains_for(rerun).count
      assert_equal 2, ChainRecord.count
      assert_equal "failed", source.reload.status
      assert_equal callback_time.to_i, source.callbacks_dispatched_at.to_i
      assert_equal [historical_step.id], source.steps.pluck(:id)
    end

    test "each rerun submission intentionally creates a separate execution" do
      source = create_execution(type: "TestPipeline", status: "succeeded")
      headers = dashboard_csrf_headers

      2.times { post "/good_pipeline/pipelines/#{source.id}/rerun", headers: headers }

      rerun_ids = PipelineRecord.where.not(id: source.id).pluck(:id)

      assert_equal 2, rerun_ids.size
      assert_equal 2, rerun_ids.uniq.size
    end

    test "direct rerun posts reject active pipelines without writing anything" do
      ACTIVE_STATUSES.each do |status|
        source = create_execution(type: "TestPipeline", status: status)
        headers = dashboard_csrf_headers
        counts = persistence_counts

        post "/good_pipeline/pipelines/#{source.id}/rerun", headers: headers

        assert_response :see_other
        assert_redirected_to "/good_pipeline/pipelines/#{source.id}"
        assert_equal "Only finished pipelines can be re-run.", flash[:alert]
        assert_equal counts, persistence_counts
      end
    end

    test "read-only mode hides rerun controls and rejects direct posts" do
      source = create_execution(type: "TestPipeline", status: "succeeded")
      GoodPipeline.dashboard_mutations_enabled = nil

      get "/good_pipeline/pipelines/#{source.id}"

      assert_response :success
      assert_select rerun_form_selector(source), count: 0
      assert_select "button", text: "re-run pipeline", count: 0

      counts = persistence_counts
      post "/good_pipeline/pipelines/#{source.id}/rerun", headers: dashboard_csrf_headers

      assert_response :forbidden
      assert_equal counts, persistence_counts
    end

    test "rerun rejects a missing CSRF token and accepts the rendered token" do
      source = create_execution(type: "TestPipeline", status: "succeeded")
      counts = persistence_counts

      with_forgery_protection do
        post "/good_pipeline/pipelines/#{source.id}/rerun"

        assert_response :unprocessable_entity
        assert_equal counts, persistence_counts

        headers = dashboard_csrf_headers
        assert_difference -> { PipelineRecord.count }, 1 do
          post "/good_pipeline/pipelines/#{source.id}/rerun", headers: headers
        end
      end

      assert_response :see_other
      assert_match(%r{/good_pipeline/pipelines/[0-9a-f-]+\z}, URI(response.location).path)
    end

    test "stale classes invalid params and incompatible definitions fail before persistence" do
      headers = dashboard_csrf_headers
      sources = [
        create_execution(type: "RemovedPipeline", status: "failed"),
        create_execution(type: "String", status: "failed"),
        create_execution(type: "TestPipeline", status: "failed", params: %w[not an object]),
        create_execution(type: "VideoProcessingPipeline", status: "failed", params: {})
      ]

      sources.each do |source|
        counts = persistence_counts

        post "/good_pipeline/pipelines/#{source.id}/rerun", headers: headers

        assert_response :see_other
        assert_redirected_to "/good_pipeline/pipelines/#{source.id}"
        assert_equal "Pipeline could not be re-run with its stored parameters and current definition.", flash[:alert]
        assert_equal counts, persistence_counts
      end
    end

    test "GET cannot invoke the rerun endpoint" do
      source = create_execution(type: "TestPipeline", status: "succeeded")

      get "/good_pipeline/pipelines/#{source.id}/rerun"

      assert_response :not_found
      assert_equal 1, PipelineRecord.count
    end

    private

    def create_execution(type:, status:, params: {}, callbacks_dispatched_at: nil)
      PipelineRecord.create!(
        type: type,
        status: status,
        params: params,
        on_failure_strategy: "halt",
        callbacks_dispatched_at: callbacks_dispatched_at
      )
    end

    def rerun_form_selector(source)
      %(form.gp-action-form[action="/good_pipeline/pipelines/#{source.id}/rerun"][method="post"])
    end

    def assert_rerun_form(source)
      assert_select "#{rerun_form_selector(source)}[data-gp-confirm]", count: 1 do
        assert_select "button.gp-action", text: "re-run pipeline", count: 1
        assert_select 'input[name="authenticity_token"]', count: 1
      end
      assert_includes response.body, "new standalone execution"
      assert_includes response.body, "may repeat side effects"
      assert_includes response.body, "will not copy chain relationships"
    end

    def chains_for(pipeline)
      ChainRecord.where(upstream_pipeline_id: pipeline.id)
                 .or(ChainRecord.where(downstream_pipeline_id: pipeline.id))
    end

    def persistence_counts
      {
        pipelines: PipelineRecord.count,
        steps: StepRecord.count,
        chains: ChainRecord.count,
        batches: GoodJob::BatchRecord.count,
        jobs: GoodJob::Job.count
      }
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
  end
end
# rubocop:enable Minitest/MultipleAssertions
