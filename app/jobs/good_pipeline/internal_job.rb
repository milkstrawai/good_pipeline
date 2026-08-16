# frozen_string_literal: true

module GoodPipeline
  # Shared enqueue-boundary validation for jobs GoodJob may enqueue from its
  # own batch lifecycle, outside a direct Coordinator call.
  class InternalJob < ActiveJob::Base
    before_enqueue do |job|
      ExecutionConfiguration.validate_enqueue!(job.class)
    end
  end
end
