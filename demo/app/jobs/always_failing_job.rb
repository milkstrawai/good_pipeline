# frozen_string_literal: true

class AlwaysFailingJob < ApplicationJob
  class AlwaysFailingError < StandardError
  end

  retry_on AlwaysFailingError, wait: 0, attempts: 3

  def perform(**_kwargs)
    raise AlwaysFailingError, "always fails"
  end
end
