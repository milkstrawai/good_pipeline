# frozen_string_literal: true

module GoodPipeline
  class CycleDetector
    class << self
      def check!(steps, edges)
        color = Hash.new(:white)
        path = []

        steps.each_key do |key|
          next if color[key] == :black

          dfs(key, edges, color, path)
        end
      end

      private

      def dfs(node, edges, color, path)
        color[node] = :grey
        path.push(node)

        (edges[node] || []).each do |neighbor|
          raise_cycle!(path, neighbor) if color[neighbor] == :grey
          dfs(neighbor, edges, color, path) if color[neighbor] == :white
        end

        path.pop
        color[node] = :black
      end

      def raise_cycle!(path, neighbor)
        cycle = path.drop_while { |node| node != neighbor } + [neighbor]
        raise InvalidPipelineError, "cycle detected: #{cycle.map { |key| ":#{key}" }.join(" -> ")}"
      end
    end
  end
end
