# frozen_string_literal: true

module GoodPipeline
  module Dashboard
    # Database name and PostgreSQL major version displayed in the dashboard
    # topbar. The SHOW query is deliberately memoized for the lifetime of the
    # process so it never becomes part of per-request dashboard query budgets.
    class ConnectionInfo
      attr_reader :database, :version, :server_version_num

      class << self
        def fetch(connection: default_connection) # rubocop:disable Metrics/MethodLength
          pid = Process.pid
          return @instance if @instance && @pid == pid

          mutex.synchronize do
            return @instance if @instance && @pid == pid

            version_num = connection.select_value("SHOW server_version_num").to_i
            @instance = new(
              database: database_name(connection),
              version: "pg#{version_num / 10_000}",
              server_version_num: version_num
            )
            @pid = pid
            @instance
          end
        end

        # Public primarily to keep isolated tests deterministic. Production
        # code should rely on the process-lifetime memoization in .fetch.
        def reset!
          mutex.synchronize do
            @instance = nil
            @pid = nil
          end
        end

        private

        def default_connection
          if defined?(GoodPipeline::PipelineRecord)
            GoodPipeline::PipelineRecord.connection
          else
            ActiveRecord::Base.connection
          end
        end

        def database_name(connection)
          config = connection.pool.db_config if connection.respond_to?(:pool)
          config&.database.to_s
        end

        def mutex
          @mutex ||= Mutex.new
        end
      end

      def initialize(database:, version:, server_version_num: nil)
        @database = database.to_s.freeze
        @version = version.to_s.freeze
        @server_version_num = server_version_num&.to_i
        freeze
      end
    end
  end
end
