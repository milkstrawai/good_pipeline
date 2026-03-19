# frozen_string_literal: true

class FailingJob < ApplicationJob
  class FailingError < StandardError
  end

  discard_on FailingError

  def perform(**)
    raise FailingError, "intentional failure"
  end
end
