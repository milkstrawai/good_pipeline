# frozen_string_literal: true

require "test_helper"

class TestChain < Minitest::Test
  class FakePipelineRecord
    attr_accessor :id, :status, :params, :type, :steps, :dependencies,
                  :callbacks_dispatched_at, :on_failure_strategy

    def initialize(attributes = {})
      attributes.each { |key, value| public_send(:"#{key}=", value) }
    end

    def terminal? = %w[succeeded failed halted skipped].include?(status)
    def halt_triggered? = false
    def reload = self
  end

  def test_initialize_wraps_single_record_in_array
    record = FakePipelineRecord.new(id: 1, status: "running")
    chain = GoodPipeline::Chain.new(record)

    assert_equal [record], chain.pipeline_records
  end

  def test_initialize_preserves_array_of_records
    records = [
      FakePipelineRecord.new(id: 1, status: "running"),
      FakePipelineRecord.new(id: 2, status: "pending")
    ]
    chain = GoodPipeline::Chain.new(records)

    assert_equal records, chain.pipeline_records
  end

  def test_delegates_id_to_first_record
    record = FakePipelineRecord.new(id: 42, status: "running")
    chain = GoodPipeline::Chain.new(record)

    assert_equal 42, chain.id
  end

  def test_delegates_status_to_first_record
    record = FakePipelineRecord.new(id: 1, status: "succeeded")
    chain = GoodPipeline::Chain.new(record)

    assert_equal "succeeded", chain.status
  end

  def test_delegates_params_to_first_record
    record = FakePipelineRecord.new(id: 1, status: "running", params: { video_id: 5 })
    chain = GoodPipeline::Chain.new(record)

    assert_equal({ video_id: 5 }, chain.params)
  end

  def test_delegates_type_to_first_record
    record = FakePipelineRecord.new(id: 1, status: "running", type: "VideoProcessing")
    chain = GoodPipeline::Chain.new(record)

    assert_equal "VideoProcessing", chain.type
  end

  def test_delegates_terminal_to_first_record
    succeeded = FakePipelineRecord.new(id: 1, status: "succeeded")
    running = FakePipelineRecord.new(id: 2, status: "running")

    assert_predicate GoodPipeline::Chain.new(succeeded), :terminal?
    refute_predicate GoodPipeline::Chain.new(running), :terminal?
  end

  def test_delegates_reload_to_first_record
    record = FakePipelineRecord.new(id: 1, status: "running")
    chain = GoodPipeline::Chain.new(record)

    assert_equal record, chain.reload
  end

  def test_with_multiple_records_delegates_to_first
    first_record = FakePipelineRecord.new(id: 1, status: "succeeded")
    second_record = FakePipelineRecord.new(id: 2, status: "failed")
    chain = GoodPipeline::Chain.new([first_record, second_record])

    assert_equal 1, chain.id
    assert_equal "succeeded", chain.status
  end
end
