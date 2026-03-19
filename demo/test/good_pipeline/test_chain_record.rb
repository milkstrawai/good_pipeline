# frozen_string_literal: true

require "test_helper"

class TestChainRecord < ActiveSupport::TestCase
  # --- Pipeline chain navigation ---
  #
  # A -> B -> C

  def test_serial_chain_navigation
    pipeline_a = create_pipeline(type: "PipelineA")
    pipeline_b = create_pipeline(type: "PipelineB")
    pipeline_c = create_pipeline(type: "PipelineC")

    GoodPipeline::ChainRecord.create!(upstream_pipeline: pipeline_a, downstream_pipeline: pipeline_b)
    GoodPipeline::ChainRecord.create!(upstream_pipeline: pipeline_b, downstream_pipeline: pipeline_c)

    # A's downstream: B
    assert_equal [pipeline_b.id], pipeline_a.downstream_chains.map(&:downstream_pipeline_id)

    # B's upstream: A, B's downstream: C
    assert_equal [pipeline_a.id], pipeline_b.upstream_chains.map(&:upstream_pipeline_id)
    assert_equal [pipeline_c.id], pipeline_b.downstream_chains.map(&:downstream_pipeline_id)

    # C's upstream: B
    assert_equal [pipeline_b.id], pipeline_c.upstream_chains.map(&:upstream_pipeline_id)
    assert_empty pipeline_c.downstream_chains
  end
end
