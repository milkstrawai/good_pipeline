# frozen_string_literal: true

class RetryableJob < ApplicationJob
  class RetryableError < StandardError
  end

  retry_on RetryableError, wait: 0, attempts: 5

  def perform(tracker_key:)
    result = ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql(
        ["UPDATE attempt_trackers SET count = count + 1 WHERE key = ? RETURNING count", tracker_key]
      )
    )
    count = result.first["count"]

    raise RetryableError, "attempt #{count}" if count < 3
  end
end
