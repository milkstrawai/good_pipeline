# frozen_string_literal: true

module GoodPipeline
  # Produces only the Mermaid graph body. Theme-dependent class definitions are
  # appended by dashboard.js so changing theme can never reuse stale colours.
  # User-controlled step keys are labels only; generated n0..nN identifiers are
  # used everywhere in the graph syntax.
  class MermaidDiagramBuilder # rubocop:disable Metrics/ClassLength
    MAX_EDGES = 1_000
    MAX_LABEL_LENGTH = 64
    STATUSES = %w[pending running enqueued succeeded failed halted canceled skipped skipped_by_branch].freeze
    Edge = Struct.new(:upstream, :downstream, keyword_init: true)
    private_constant :Edge

    def initialize(pipeline) # rubocop:disable Metrics/AbcSize
      @pipeline = pipeline
      @steps = ordered_steps(pipeline.steps)
      @dependencies = Array(pipeline.dependencies)
      @step_by_token = @steps.to_h { |step| [step_token(step), step] }
      @node_id_by_token = @steps.each_with_index.to_h { |step, index| [step_token(step), "n#{index}"] }
      @node_id_by_key = @steps.to_h { |step| [step.key.to_s, @node_id_by_token.fetch(step_token(step))] }
      @terminal_node_id = "n#{@steps.length}"
      @edges = dependency_edges
      @edge_count = @dependencies.length
    end

    def definition_diagram
      build_diagram do |step|
        next "branch" if branch_step?(step)
        next "barrier" if barrier_step?(step)

        "step"
      end
    end

    def status_diagram
      build_diagram do |step|
        branch_step?(step) ? "branch" : safe_status(step)
      end
    end

    def diagram(mode: :status)
      mode.to_sym == :definition ? definition_diagram : status_diagram
    end

    def overflow? = edge_count > MAX_EDGES
    alias edge_overflow? overflow?
    def renderable? = !overflow?

    # The number of actual Mermaid arrows includes synthetic terminal and
    # empty-branch-arm edges. `edge_count` intentionally remains the persisted
    # DAG dependency count used by the product's >1000-edge contract.
    def rendered_edge_count
      @rendered_edge_count ||= begin
        terminal_edges = visible_terminal_steps.length
        empty_arm_edges = empty_arm_edge_lines.length
        visible_dependency_edges.length + terminal_edges + empty_arm_edges
      end
    end

    def node_ids
      @node_id_by_key.dup.freeze
    end

    attr_reader :edge_count, :terminal_node_id

    def payload(mode: :status)
      {
        graph: diagram(mode: mode),
        edge_count: edge_count,
        overflow: overflow?
      }.freeze
    end

    private

    def build_diagram # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      lines = ["graph TD"]
      @steps.each do |step|
        node_id = node_id_for(step)
        label = escape_label(Dashboard::Topology.label_for(step))
        css_class = yield(step)
        lines << if barrier_step?(step)
                   %(  #{node_id}[["#{label}"]]:::#{css_class})
                 elsif branch_step?(step)
                   %(  #{node_id}{"#{label}"}:::#{css_class})
                 else
                   %(  #{node_id}("#{label}"):::#{css_class})
                 end
      end

      visible_dependency_edges.each { |edge| lines << dependency_edge_line(edge) }
      lines << %(  #{@terminal_node_id}((" ")):::terminal)
      visible_terminal_steps.each { |step| lines << "  #{node_id_for(step)} --> #{@terminal_node_id}" }
      lines.concat(empty_arm_edge_lines)
      lines.join("\n")
    end

    def dependency_edges
      @dependencies.filter_map do |dependency|
        upstream_ref, downstream_ref = dependency_endpoints(dependency)
        upstream = resolve_step(upstream_ref)
        downstream = resolve_step(downstream_ref)
        Edge.new(upstream: upstream, downstream: downstream).freeze if upstream && downstream
      end
    end

    def dependency_edge_line(edge)
      from = node_id_for(edge.upstream)
      to = node_id_for(edge.downstream)
      if branch_step?(edge.upstream) && branch_arm_step?(edge.downstream)
        label = escape_edge_label(edge.downstream.branch_arm)
        label.empty? ? "  #{from} --> #{to}" : "  #{from} -->|#{label}| #{to}"
      else
        "  #{from} --> #{to}"
      end
    end

    def terminal_steps
      @terminal_steps ||= begin
        has_downstream = @edges.to_set { |edge| step_token(edge.upstream) }
        @steps.reject { |step| has_downstream.include?(step_token(step)) }
      end
    end

    def visible_dependency_edges
      @visible_dependency_edges ||= @edges.reject { |edge| hidden_dependency_edge?(edge) }
    end

    def hidden_dependency_edge?(edge)
      all_empty_branch?(edge.upstream) ||
        (branch_step?(edge.upstream) && barrier_step?(edge.downstream))
    end

    def visible_terminal_steps
      @visible_terminal_steps ||= terminal_steps.reject { |step| all_empty_branch?(step) }
    end

    def empty_arm_edge_lines # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      @empty_arm_edge_lines ||= begin
        branch_arm_steps = @steps.select { |step| branch_arm_step?(step) }.group_by do |step|
          step.branch_key.to_s
        end

        @steps.select { |step| branch_step?(step) }.flat_map do |branch_step|
          Array(branch_step.empty_arms).flat_map do |arm_name|
            targets = post_branch_targets(branch_step, branch_arm_steps)
            label = escape_edge_label(arm_name)
            if targets.empty?
              [labelled_edge(node_id_for(branch_step), @terminal_node_id, label)]
            else
              targets.map { |target| labelled_edge(node_id_for(branch_step), node_id_for(target), label) }
            end
          end
        end
      end
    end

    def post_branch_targets(branch_step, branch_arm_steps) # rubocop:disable Metrics/AbcSize
      arm_tokens = Array(branch_arm_steps[branch_step.key.to_s]).to_set { |step| step_token(step) }
      return direct_branch_targets(branch_step) if arm_tokens.empty?

      target_tokens = @edges.filter_map do |edge|
        upstream_token = step_token(edge.upstream)
        downstream_token = step_token(edge.downstream)
        downstream_token if arm_tokens.include?(upstream_token) && !arm_tokens.include?(downstream_token)
      end.to_set
      @steps.select { |step| target_tokens.include?(step_token(step)) }
    end

    def direct_branch_targets(branch_step)
      target_tokens = @edges.filter_map do |edge|
        step_token(edge.downstream) if step_token(edge.upstream) == step_token(branch_step)
      end.to_set
      @steps.select { |step| target_tokens.include?(step_token(step)) }
    end

    def labelled_edge(from, to, label)
      label.empty? ? "  #{from} --> #{to}" : "  #{from} -->|#{label}| #{to}"
    end

    def dependency_endpoints(dependency) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      if dependency.is_a?(Hash)
        upstream = dependency[:depends_on_step_id] || dependency["depends_on_step_id"] ||
                   dependency[:from] || dependency["from"]
        downstream = dependency[:step_id] || dependency["step_id"] ||
                     dependency[:to] || dependency["to"]
        return [upstream, downstream]
      end
      return [dependency[0], dependency[1]] if dependency.is_a?(Array)

      upstream = dependency.depends_on_step_id if dependency.respond_to?(:depends_on_step_id)
      downstream = dependency.step_id if dependency.respond_to?(:step_id)
      upstream ||= dependency.depends_on_step if dependency.respond_to?(:depends_on_step)
      downstream ||= dependency.step if dependency.respond_to?(:step)
      [upstream, downstream]
    end

    def resolve_step(reference)
      return if reference.nil?

      token = step_token(reference)
      @step_by_token[token] || @steps.find { |step| step.key.to_s == reference.to_s }
    end

    def ordered_steps(steps)
      records = Array(steps)
      return records unless records.all? do |step|
        step.respond_to?(:created_at) && step.respond_to?(:id) && step.created_at && step.id
      end

      records.sort_by { |step| [step.created_at, step.id.to_s] }
    end

    def step_token(step)
      return unless step
      return step.to_s unless step.respond_to?(:key)

      id = step.id if step.respond_to?(:id)
      (id.nil? || id.to_s.empty? ? step.key : id).to_s
    end

    def node_id_for(step)
      @node_id_by_token.fetch(step_token(step))
    end

    def branch_step?(step)
      return step.branch_step? if step.respond_to?(:branch_step?)

      step.respond_to?(:job_class) && step.job_class.to_s == GoodPipeline::BRANCH_JOB_CLASS
    end

    def branch_arm_step?(step)
      return step.branch_arm_step? if step.respond_to?(:branch_arm_step?)

      step.respond_to?(:branch_arm) && !step.branch_arm.to_s.empty?
    end

    def barrier_step?(step)
      Dashboard::Topology.barrier_step?(step)
    end

    def all_empty_branch?(step)
      return false unless branch_step?(step) && Array(step.empty_arms).any?

      @steps.none? do |candidate|
        branch_arm_step?(candidate) && candidate.branch_key.to_s == step.key.to_s
      end
    end

    def safe_status(step)
      status = step.respond_to?(:coordination_status) ? step.coordination_status.to_s : "pending"
      STATUSES.include?(status) ? status : "pending"
    end

    def escape_label(value)
      clean = value.to_s.gsub(/[\u0000-\u001f\u007f]/, "").gsub('"', "#quot;")
      clean.each_char.first(MAX_LABEL_LENGTH).join
    end

    def escape_edge_label(value)
      escape_label(value).gsub(/[^\w .:-]/, "").each_char.first(MAX_LABEL_LENGTH).join
    end
  end
end
