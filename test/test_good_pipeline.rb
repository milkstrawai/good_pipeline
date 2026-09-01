# frozen_string_literal: true

require "test_helper"

class TestGoodPipeline < Minitest::Test
  def teardown
    GoodPipeline.dashboard_mutations_enabled = nil
  end

  def test_that_it_has_a_version_number
    refute_nil ::GoodPipeline::VERSION
  end

  def test_dashboard_mutations_are_disabled_by_default
    GoodPipeline.dashboard_mutations_enabled = nil

    refute_predicate GoodPipeline, :dashboard_mutations_enabled?
  end

  def test_dashboard_mutations_require_literal_true
    GoodPipeline.dashboard_mutations_enabled = "true"

    refute_predicate GoodPipeline, :dashboard_mutations_enabled?

    GoodPipeline.dashboard_mutations_enabled = true

    assert_predicate GoodPipeline, :dashboard_mutations_enabled?
  end
end
