# frozen_string_literal: true

class HaltExecutionJob < ApplicationJob
  def perform(**)
    halt_pipeline!
  end
end
