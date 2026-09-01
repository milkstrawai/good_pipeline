# frozen_string_literal: true

module GoodPipeline
  module Dashboard
    # Shared, query-free topology helpers for execution and definition stages.
    module Topology
      module_function

      def ordered_steps(steps)
        records = Array(steps)
        return records unless records.all? { |step| timestamped?(step) }

        records.sort_by { |step| [step.created_at, step.id.to_s] }
      end

      def tokens(steps)
        steps.to_h { |step| [step, token_for(step)] }
      end

      # Input adapters account for both Active Record dependencies and plain
      # StepDefinition dependency keys.
      def dependency_pairs(steps, dependencies) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        step_tokens = tokens(steps)
        references = reference_map(step_tokens)
        explicit = Array(dependencies)

        pairs = explicit.filter_map do |dependency|
          upstream, downstream = endpoints(dependency)
          upstream_token = resolve(upstream, references, step_tokens)
          downstream_token = resolve(downstream, references, step_tokens)
          [upstream_token, downstream_token] if upstream_token && downstream_token
        end

        return pairs.uniq unless pairs.empty? && explicit.empty?

        steps.flat_map do |step|
          next [] unless step.respond_to?(:dependencies)

          Array(step.dependencies).filter_map do |upstream|
            upstream_token = resolve(upstream, references, step_tokens)
            [upstream_token, step_tokens.fetch(step)] if upstream_token
          end
        end.uniq
      end

      def levels(steps, pairs) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        step_tokens = tokens(steps)
        upstream = Hash.new { |hash, key| hash[key] = [] }
        step_tokens.each_value { |token| upstream[token] }
        pairs.each { |from, to| upstream[to] << from if upstream.key?(to) }

        memo = {}
        visiting = {}
        depth = lambda do |token|
          return memo[token] if memo.key?(token)
          return 0 if visiting[token] # Defensive only; stored graphs are validated DAGs.

          visiting[token] = true
          parents = upstream[token]
          memo[token] = parents.empty? ? 0 : parents.map { |parent| depth.call(parent) }.max + 1
          visiting.delete(token)
          memo[token]
        end
        step_tokens.each_value { |token| depth.call(token) }
        memo
      end

      def token_for(step)
        id = step.id if step.respond_to?(:id)
        (id.nil? || id.to_s.empty? ? step.key : id).to_s
      end

      def branch_step?(step)
        return step.branch_step? if step.respond_to?(:branch_step?)

        step.respond_to?(:job_class) && step.job_class.to_s == GoodPipeline::BRANCH_JOB_CLASS
      end

      def endpoints(dependency) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        return [dependency[0], dependency[1]] if dependency.is_a?(Array)

        if dependency.is_a?(Hash)
          upstream = dependency[:depends_on_step_id] || dependency["depends_on_step_id"] ||
                     dependency[:from] || dependency["from"]
          downstream = dependency[:step_id] || dependency["step_id"] ||
                       dependency[:to] || dependency["to"]
          return [upstream, downstream]
        end

        upstream = dependency.depends_on_step_id if dependency.respond_to?(:depends_on_step_id)
        downstream = dependency.step_id if dependency.respond_to?(:step_id)
        upstream ||= dependency.depends_on_step if dependency.respond_to?(:depends_on_step)
        downstream ||= dependency.step if dependency.respond_to?(:step)
        [upstream, downstream]
      end

      def timestamped?(step)
        step.respond_to?(:created_at) && step.respond_to?(:id) && step.created_at && step.id
      end
      private_class_method :timestamped?

      def reference_map(step_tokens)
        step_tokens.each_with_object({}) do |(step, token), map|
          map[token] = token
          map[step.id.to_s] = token if step.respond_to?(:id) && step.id
          map[step.key.to_s] = token if step.respond_to?(:key)
        end
      end
      private_class_method :reference_map

      def resolve(reference, references, step_tokens)
        return step_tokens[reference] if step_tokens.key?(reference)
        return if reference.nil?

        references[reference.to_s]
      end
      private_class_method :resolve
    end

    # Aggregates execution steps into compact stage timeline lanes.
    class StageLanes # rubocop:disable Metrics/ClassLength
      STATUS_PRIORITY = {
        "failed" => 6,
        "halted" => 5,
        "enqueued" => 4,
        "running" => 4,
        "pending" => 3,
        "canceled" => 2,
        "skipped" => 2,
        "skipped_by_branch" => 2,
        "succeeded" => 1
      }.freeze

      STATUS_LABEL = {
        "pending" => "pending",
        "running" => "running",
        "enqueued" => "enqueued",
        "succeeded" => "succeeded",
        "failed" => "failed",
        "halted" => "halted",
        "canceled" => "canceled",
        "skipped" => "skipped",
        "skipped_by_branch" => "skipped\u00B7br"
      }.freeze

      Member = Struct.new(
        :step, :status, :level, :performed_at, :finished_at,
        :t0, :t1, :start_s, :dur_s, :timed, :open_ended,
        keyword_init: true
      ) do
        alias_method :duration, :dur_s
        alias_method :duration_s, :dur_s
        def timed? = timed
        def striped? = open_ended
      end

      Lane = Struct.new(
        :stage, :label, :level, :n, :counts, :worst,
        :t0, :t1, :dur_s, :note, :timed_count, :open_ended,
        :members, # rubocop:disable Lint/StructNewOverride -- intentional dashboard value field
        keyword_init: true
      ) do
        alias_method :duration, :dur_s
        alias_method :duration_s, :dur_s
        alias_method :duration_seconds, :dur_s
        def timed? = timed_count.to_i.positive?
        def striped? = open_ended
      end

      def initialize(steps:, dependencies:, timings:, pipeline:, now: Time.current)
        @steps = Topology.ordered_steps(steps)
        @dependencies = Array(dependencies)
        @timings = timings || {}
        @pipeline = pipeline
        @now = now
      end

      def call
        pairs = Topology.dependency_pairs(@steps, @dependencies)
        levels = Topology.levels(@steps, pairs)
        members = @steps.map { |step| build_member(step, levels.fetch(Topology.token_for(step), 0)) }
        aggregate(members)
      end

      private

      def build_member(step, level) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        status = step.coordination_status.to_s
        performed_at, finished_at = timing_for(step)
        timed = !performed_at.nil?
        endpoint = finished_at || timeline_end if timed
        endpoint = performed_at if endpoint && endpoint < performed_at

        Member.new(
          step: step,
          status: status,
          level: level,
          performed_at: performed_at,
          finished_at: finished_at,
          t0: timed ? fraction(performed_at) : nil,
          t1: timed ? [fraction(endpoint), fraction(performed_at)].max : nil,
          start_s: timed ? performed_at - timeline_start : nil,
          dur_s: timed ? endpoint - performed_at : nil,
          timed: timed,
          open_ended: timed && finished_at.nil?
        ).freeze
      end

      def aggregate(members) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        groups = {}
        order = []
        members.each do |member|
          stage = member.step.key.to_s.sub(/_\d+\z/, "")
          group_key = "#{stage}@#{member.level}"
          unless groups.key?(group_key)
            groups[group_key] = { stage: stage, level: member.level, members: [] }
            order << group_key
          end
          groups[group_key][:members] << member
        end

        order.map { |group_key| build_lane(groups.fetch(group_key)) }
      end

      def build_lane(group) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        members = group.fetch(:members)
        timed = members.select(&:timed)
        counts = members.each_with_object(Hash.new(0)) { |member, tally| tally[member.status] += 1 }.to_h.freeze
        worst = members.max_by { |member| STATUS_PRIORITY.fetch(member.status, 0) }&.status || "pending"

        Lane.new(
          stage: group.fetch(:stage),
          label: lane_label(group.fetch(:stage), members.length),
          level: group.fetch(:level),
          n: members.length,
          counts: counts,
          worst: worst,
          t0: timed.map(&:t0).min,
          t1: timed.map(&:t1).max,
          dur_s: lane_duration(timed),
          note: timed.empty? ? STATUS_LABEL.fetch(worst, worst) : nil,
          timed_count: timed.length,
          open_ended: timed.any?(&:open_ended),
          members: members.freeze
        ).freeze
      end

      def timing_for(step) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        return [nil, nil] unless step.respond_to?(:good_job_id) && step.good_job_id

        value = @timings[step.good_job_id] || @timings[step.good_job_id.to_s]
        case value
        when Array
          value
        when Hash
          [value[:performed_at] || value["performed_at"], value[:finished_at] || value["finished_at"]]
        else
          if value.respond_to?(:performed_at)
            [value.performed_at, value.finished_at]
          else
            [nil, nil]
          end
        end
      end

      def lane_duration(timed)
        return if timed.empty?

        timed.map { |member| member.start_s + member.dur_s }.max - timed.map(&:start_s).min
      end

      def lane_label(stage, count)
        count > 1 ? "#{stage} \u00D7#{count}" : stage
      end

      def fraction(time)
        value = (time - timeline_start).to_f / timeline_duration
        value.clamp(0.0, 1.0)
      end

      def timeline_start = @pipeline.created_at

      def timeline_end
        terminal = @pipeline.respond_to?(:terminal?) && @pipeline.terminal?
        terminal ? @pipeline.updated_at : @now
      end

      def timeline_duration
        @timeline_duration ||= [(timeline_end - timeline_start).to_f, 1.0].max
      end
    end
  end
end
