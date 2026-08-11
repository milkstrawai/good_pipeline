# frozen_string_literal: true

# `active_support/time` installs the duration extensions used by FilterSet, but
# it does not initialize everything Time.current needs when Active Support is
# required outside Rails. Keep these requires in this order.
require "active_support"
require "active_support/time"
require_relative "version"

module GoodPipeline
  module Dashboard
  end
end

require_relative "dashboard/connection_info"
require_relative "dashboard/filter_set"
require_relative "dashboard/sparkline"
require_relative "dashboard/kpi_calculator"
require_relative "dashboard/step_timings"
require_relative "dashboard/stage_lanes"
require_relative "dashboard/definition_stages"
