# frozen_string_literal: true

module GoodPipeline
  # Durable, at-least-once delivery for one committed pipeline-chain edge.
  # Downstream coordination is row-locked and idempotent, so retries, duplicate
  # delivery, and a crash after the transition commit are harmless.
  class ChainPropagationJob < InternalJob
    retry_on ActiveRecord::Deadlocked,
             ActiveRecord::ConnectionFailed,
             ActiveRecord::ConnectionNotEstablished,
             ActiveRecord::ConnectionTimeoutError,
             ActiveRecord::LockWaitTimeout,
             ActiveRecord::SerializationFailure,
             wait: :polynomially_longer,
             attempts: 5

    def perform(chain_record_id)
      GoodPipeline::ChainCoordinator.propagate_edge(chain_record_id)
    end
  end
end
