# frozen_string_literal: true

require "test_helper"
require "date"

class TestDashboard < Minitest::Test
  Step = Struct.new(
    :id, :key, :coordination_status, :good_job_id, :created_at, :job_class,
    keyword_init: true
  ) do
    def branch_step? = job_class == GoodPipeline::BRANCH_JOB_CLASS
    def barrier_step? = job_class == GoodPipeline::BARRIER_JOB_CLASS
  end
  Pipeline = Struct.new(:created_at, :updated_at, :terminal, keyword_init: true) do
    def terminal? = terminal
  end

  def test_plain_require_installs_duration_and_current_time_support
    assert_equal 86_400, 24.hours
    assert_instance_of Time, Time.current
  end

  def test_filter_set_coerces_unknown_values_and_is_immutable
    filters = GoodPipeline::Dashboard::FilterSet.from_params(
      status: "bogus", time: "century", pipeline_type: "", page: "abc", q: nil
    )

    assert_equal "all", filters.status
    assert_equal "all", filters.time
    assert_nil filters.pipeline_type
    assert_equal "", filters.query
    assert_equal 1, filters.page
    assert_predicate filters, :frozen?
  end

  def test_filter_set_time_cutoff
    now = Time.utc(2026, 8, 10, 12)
    filters = GoodPipeline::Dashboard::FilterSet.from_params(time: "24h", status: "running", page: -3)

    assert_equal now - 24.hours, filters.time_cutoff(now)
    assert_equal "running", filters.status
    assert_equal 1, filters.page
  end

  def test_filter_set_accepts_cancellation_statuses
    canceling = GoodPipeline::Dashboard::FilterSet.from_params(status: "canceling")
    canceled = GoodPipeline::Dashboard::FilterSet.from_params(status: "canceled")

    assert_equal "canceling", canceling.status
    assert_equal "canceled", canceled.status
  end

  def test_stage_lanes_group_by_stage_and_level_with_worst_status
    now = Time.utc(2026, 8, 10, 12)
    pipeline = Pipeline.new(created_at: now - 100, updated_at: now, terminal: true)
    plan = step(id: "p", key: "plan", status: "succeeded", job: "j-plan", at: now - 100)
    extract0 = step(id: "e0", key: "extract_00", status: "succeeded", job: "j-e0", at: now - 99)
    extract1 = step(id: "e1", key: "extract_01", status: "failed", job: "j-e1", at: now - 98)
    timings = {
      "j-plan" => [now - 95, now - 90],
      "j-e0" => [now - 80, now - 60]
    }
    dependencies = [%w[p e0], %w[p e1]]

    lanes = GoodPipeline::Dashboard::StageLanes.new(
      pipeline: pipeline,
      steps: [extract1, plan, extract0],
      dependencies: dependencies,
      timings: timings,
      now: now
    ).call

    assert_equal %w[plan extract], lanes.map(&:stage)
    extract = lanes.last

    assert_equal "extract ×2", extract.label
    assert_equal 1, extract.level
    assert_equal "failed", extract.worst
    assert_equal({ "succeeded" => 1, "failed" => 1 }, extract.counts)
    assert_equal 1, extract.timed_count
    assert_in_delta 20, extract.dur_s, 0.001
  end

  def test_stage_lane_with_no_timed_members_has_note_and_no_bar
    now = Time.utc(2026, 8, 10, 12)
    pipeline = Pipeline.new(created_at: now, updated_at: now, terminal: true)
    pending = step(id: "p", key: "load_00", status: "pending", job: "missing", at: now)

    lane = GoodPipeline::Dashboard::StageLanes.new(
      pipeline: pipeline, steps: [pending], dependencies: [], timings: {}, now: now
    ).call.first

    refute_predicate lane, :timed?
    assert_nil lane.t0
    assert_nil lane.t1
    assert_equal "pending", lane.note
  end

  def test_canceled_stage_members_are_preserved_in_counts_and_note
    now = Time.utc(2026, 8, 10, 12)
    pipeline = Pipeline.new(created_at: now, updated_at: now, terminal: true)
    canceled = step(id: "c", key: "work_00", status: "canceled", job: nil, at: now)
    succeeded = step(id: "s", key: "work_01", status: "succeeded", job: nil, at: now + 1)

    lane = GoodPipeline::Dashboard::StageLanes.new(
      pipeline: pipeline, steps: [canceled, succeeded], dependencies: [], timings: {}, now: now
    ).call.first

    assert_equal "canceled", lane.worst
    assert_equal "canceled", lane.note
    assert_equal({ "canceled" => 1, "succeeded" => 1 }, lane.counts)
  end

  def test_running_timing_is_open_ended_and_zero_duration_is_safe
    now = Time.utc(2026, 8, 10, 12)
    pipeline = Pipeline.new(created_at: now, updated_at: now, terminal: false)
    running = step(id: "r", key: "run", status: "enqueued", job: "job", at: now)

    lane = GoodPipeline::Dashboard::StageLanes.new(
      pipeline: pipeline,
      steps: [running],
      dependencies: [],
      timings: { "job" => [now, nil] },
      now: now
    ).call.first

    assert_predicate lane, :striped?
    assert_in_delta(0.0, lane.t0)
    assert_in_delta(0.0, lane.t1)
  end

  def test_definition_stages_include_branch_and_terminal_roles
    at = Time.utc(2026, 8, 10)
    first = step(id: "a", key: "prepare", status: nil, job: nil, at: at)
    branch = step(
      id: "b", key: "route", status: nil, job: nil, at: at + 1,
      job_class: GoodPipeline::BRANCH_JOB_CLASS
    )
    terminal0 = step(id: "c0", key: "write_00", status: nil, job: nil, at: at + 2)
    terminal1 = step(id: "c1", key: "write_01", status: nil, job: nil, at: at + 3)

    stages = GoodPipeline::Dashboard::DefinitionStages.new(
      steps: [first, branch, terminal0, terminal1],
      dependencies: [%w[a b], %w[b c0], %w[b c1]]
    ).call

    assert_equal %i[step branch terminal], stages.map(&:role)
    assert_equal "write ×2", stages.last.label
    assert_equal 2, stages.last.n
  end

  def test_definition_stages_include_readable_barrier_role
    at = Time.utc(2026, 8, 10)
    first = step(id: "a", key: "prepare", status: nil, job: nil, at: at)
    barrier = step(
      id: "b", key: "__good_pipeline_barrier_1", status: nil, job: nil, at: at + 1,
      job_class: GoodPipeline::BARRIER_JOB_CLASS
    )
    terminal = step(id: "c", key: "publish", status: nil, job: nil, at: at + 2)

    stages = GoodPipeline::Dashboard::DefinitionStages.new(
      steps: [first, barrier, terminal], dependencies: [%w[a b], %w[b c]]
    ).call

    assert_equal %i[step barrier terminal], stages.map(&:role)
    assert_equal "Barrier 1", stages[1].label
  end

  def test_step_timings_returns_running_and_completed_rows_and_omits_missing
    rows = [
      ["complete", Time.at(10), Time.at(15)],
      ["running", Time.at(20), nil]
    ]
    relation = Object.new
    relation.define_singleton_method(:pluck) { |*| rows }
    model = Object.new
    model.define_singleton_method(:where) do |id:|
      raise "unexpected ids" unless id.sort == %w[complete missing running]

      relation
    end

    timings = GoodPipeline::Dashboard::StepTimings.new(
      %w[complete running missing], job_model: model
    ).call

    assert_equal [Time.at(10), Time.at(15)], timings["complete"]
    assert_equal [Time.at(20), nil], timings["running"]
    refute timings.key?("missing")
  end

  def test_sparkline_zero_fills_fourteen_days_and_handles_all_zero_heights
    connection = FakeConnection.new(rows: [])
    sparkline = GoodPipeline::Dashboard::Sparkline.new(
      now: Time.utc(2026, 8, 10, 12), connection: connection
    )

    assert_equal [0] * 14, sparkline.buckets
    assert_equal [0.0] * 14, sparkline.heights
  end

  def test_kpis_keep_old_running_execution_and_zero_prior_period
    values = {
      "running_now" => 1,
      "last_24h" => 4,
      "failed_7d" => 2,
      "failed_prior_7d" => 0,
      "p50" => 12.5,
      "p95" => 29.0,
      "enqueued_steps" => 3
    }
    connection = FakeConnection.new(values: values, rows: [])
    result = GoodPipeline::Dashboard::KpiCalculator.new(
      pipeline_type: "VideoPipeline",
      now: Time.utc(2026, 8, 10, 12),
      connection: connection,
      cache: nil
    ).call

    assert_equal 1, result.running_now
    assert_equal 0, result.failed_prior_7d
    assert_in_delta(12.5, result.p50)
    assert_equal [0] * 14, result.sparkline
    sql = connection.sql.join("\n")

    assert_includes sql, "p.status IN ('running', 'canceling') OR"
    assert_includes sql, "'halted', 'canceled', 'skipped'"
    assert_includes sql, "p.status = 'failed' AND"
    assert_includes sql, "p.type = 'VideoPipeline'"
    assert_equal 2, sql.scan("'halted', 'canceled', 'skipped'").length
    assert_equal 2, sql.scan("p.status = 'failed'").length
  end

  private

  def step(id:, key:, status:, job:, at:, job_class: "DemoJob")
    Step.new(
      id: id,
      key: key,
      coordination_status: status,
      good_job_id: job,
      created_at: at,
      job_class: job_class
    )
  end

  class FakeConnection
    attr_reader :sql

    def initialize(values: {}, rows: [])
      @values = values
      @rows = rows
      @sql = []
    end

    def quote(value)
      value.is_a?(String) ? "'#{value.gsub("'", "''")}'" : "'#{value}'"
    end

    def select_one(statement)
      @sql << statement
      @values
    end

    def select_all(statement)
      @sql << statement
      @rows
    end
  end
end
