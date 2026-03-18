# frozen_string_literal: true

module GoodPipeline
  class CycleDetector
    def self.check!(steps, edges)
      color = Hash.new(:white)
      path = []

      steps.each_key do |key|
        next if color[key] == :black

        dfs(key, edges, color, path)
      end
    end

    def self.dfs(node, edges, color, path)
      color[node] = :grey
      path.push(node)

      (edges[node] || []).each do |neighbor|
        raise_cycle!(path, neighbor) if color[neighbor] == :grey
        dfs(neighbor, edges, color, path) if color[neighbor] == :white
      end

      path.pop
      color[node] = :black
    end

    def self.raise_cycle!(path, neighbor)
      cycle = path.drop_while { |n| n != neighbor } + [neighbor]
      raise InvalidPipelineError, "cycle detected: #{cycle.map { |k| ":#{k}" }.join(" -> ")}"
    end

    private_class_method :dfs, :raise_cycle!
  end
end
