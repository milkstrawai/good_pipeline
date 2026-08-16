# frozen_string_literal: true

module GoodPipeline
  class Coordinator # rubocop:disable Metrics/ClassLength
    class << self
      # Applies a step outcome reported by its GoodJob batch callback.
      #
      # The claim requires the step to still be `enqueued` AND owned by the
      # reporting batch: a stale callback — a duplicate delivery, or a GoodJob-UI
      # retry of a previous attempt's batch — is ignored rather than allowed to
      # stamp a newer attempt with an older outcome. The pipeline row is locked
      # first, so halt policy commits atomically with the step outcome and the
      # global pipeline→step lock order holds.
      #
      # An unclaimed callback still recomputes: a crash between the outcome
      # commit and the settlement recompute leaves the outcome durable while the
      # pipeline is still `running`, and GoodJob's redelivery of this job — which
      # then finds nothing to claim — is the only actor left to settle it.
      # Recompute is idempotent, so this costs nothing on genuinely stale
      # deliveries.
      def complete_step(step_id:, batch_id:, succeeded:) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        pipeline_id = StepRecord.where(id: step_id).pick(:pipeline_id)
        return if pipeline_id.nil?

        anything_enqueued = false

        StepRecord.transaction do
          pipeline = PipelineRecord.lock("FOR UPDATE").find_by(id: pipeline_id)
          next if pipeline.nil?

          locked_step = StepRecord.lock("FOR UPDATE").find_by(
            id: step_id, coordination_status: "enqueued", good_job_batch_id: batch_id
          )
          next if locked_step.nil?

          if succeeded && locked_step.halt_requested?
            locked_step.transition_coordination_status_to!(:halted)
            pipeline.steps.pending.update_all(coordination_status: "skipped")
            next
          end

          record_step_outcome(locked_step, succeeded)
          propagate_halt(locked_step) if !succeeded && pipeline.halt?
          anything_enqueued = unblock_downstream_steps(locked_step)
        end

        return if anything_enqueued

        recompute_settled_pipeline(pipeline_id)
      end

      def try_enqueue_step(step_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        step_was_enqueued = false
        skipped_downstream_ids = nil
        recompute_pipeline_id = nil

        begin
          # requires_new: an attempt that fails configuration must roll back its
          # partial writes even when this call is nested inside a caller's
          # transaction, where a plain nested transaction would silently join
          # and leak them on the outer commit.
          StepRecord.transaction(requires_new: true) do
            locked_step = StepRecord.lock("FOR UPDATE").find_by(id: step_id)
            return false unless locked_step&.pending?
            return false if locked_step.good_job_id.present?

            skipped_downstream_ids = resolve_step(locked_step)
            step_was_enqueued = skipped_downstream_ids.nil?
          end
        rescue ConfigurationError => error
          skipped_downstream_ids, recompute_pipeline_id = fail_step_for_configuration_error(step_id, error)
        end

        downstream_enqueued = false
        skipped_downstream_ids&.each { |id| downstream_enqueued = true if try_enqueue_step(id) }
        recompute_settled_pipeline(recompute_pipeline_id) if recompute_pipeline_id
        step_was_enqueued || downstream_enqueued
      end

      # Enqueues multiple steps in bulk using Batch.enqueue_all.
      # Intended for root steps during pipeline startup; serialization against
      # cancel and in-flight single-step enqueues happens under the pipeline
      # lock inside bulk_enqueue_user_jobs.
      def bulk_enqueue_steps(step_ids) # rubocop:disable Metrics/MethodLength
        return if step_ids.empty?

        steps = StepRecord.where(id: step_ids, coordination_status: "pending")
                          .where(good_job_id: nil)
                          .to_a
        return if steps.empty?

        # Enforced here, before partitioning could conceal mixed input: the
        # pipeline-lock serialization below is only sound within one pipeline.
        pipeline_ids = steps.map(&:pipeline_id).uniq
        if pipeline_ids.many?
          raise ArgumentError,
                "bulk_enqueue_steps expects steps of exactly one pipeline, got #{pipeline_ids.size}"
        end

        branch_steps, enqueueable_steps = steps.partition(&:branch_step?)

        bulk_enqueue_user_jobs(enqueueable_steps) if enqueueable_steps.any?

        enqueue_branch_steps(pipeline_ids.first, branch_steps)
      end

      def recompute_pipeline_status(pipeline, has_active_steps: nil) # rubocop:disable Metrics/MethodLength
        # The hint is a fast path only: callers compute it in the same statement
        # as the triggering event, and staleness is conservative — concurrent
        # actors can only add active steps, or recompute themselves after
        # removing them. Every authoritative check runs below against a freshly
        # locked row, so a stale in-memory `pipeline` (terminal or not) can
        # neither suppress nor duplicate a settlement.
        return if has_active_steps

        PipelineRecord.transaction do
          # Only a running pipeline settles: terminal rows are done, and a
          # pending row belongs to ChainCoordinator (which starts or skips it
          # under its own lock) — recompute must not derive a terminal status
          # from a pipeline that never ran.
          locked = PipelineRecord.lock("FOR UPDATE").find_by(id: pipeline.id)
          next unless locked&.running?
          next if locked.steps.where(coordination_status: %w[pending enqueued]).exists?

          new_status = derive_terminal_status(locked)
          locked.transition_to!(new_status)
          dispatch_callbacks_once(locked, new_status)

          # Chains propagate only after the outermost commit. While this
          # transaction holds the uncommitted terminal status, a concurrent
          # settler could read this pipeline as still running and skip a shared
          # downstream, stranding it; post-commit, the status is durably
          # visible to whoever locks the downstream next.
          ActiveRecord.after_all_transactions_commit do
            ChainCoordinator.propagate_terminal_state(locked)
          end
        end
      end

      # Operator-initiated cancellation. There is no reliable way to interrupt a
      # job that GoodJob has already handed to a worker, so canceling drains
      # instead of killing: pending steps are skipped immediately, in-flight
      # steps run to completion, and the pipeline reaches its terminal state
      # once the last of them reports back through StepFinishedJob.
      #
      # Returns true when this call performed the cancellation, false when the
      # pipeline was not running or another caller cancelled it first.
      # Command-query in the style of ActiveRecord#save, not a predicate.
      #
      # The claim and the settlement share one transaction. Split across two, a
      # failure of the second (a lock timeout, a lost connection, a callback
      # enqueue error) would commit `canceled_at` on a still-`running` row that
      # nothing can subsequently advance: complete_step claims only `enqueued`
      # steps, and claim_cancellation itself requires `canceled_at` to be nil.
      # recompute_pipeline_status re-locks the same row — re-entrant within this
      # transaction — and defers chain propagation past the outermost commit.
      def cancel_pipeline(pipeline)
        canceled = false

        PipelineRecord.transaction do
          next unless claim_cancellation(pipeline)

          recompute_pipeline_status(pipeline.reload)
          canceled = true
        end

        canceled
      end

      def dispatch_callbacks_once(pipeline, new_status) # rubocop:disable Metrics/MethodLength
        PipelineRecord.transaction do
          rows_updated = PipelineRecord.where(id: pipeline.id, callbacks_dispatched_at: nil)
                                       .update_all(callbacks_dispatched_at: Time.current)

          return if rows_updated.zero?

          begin
            ensure_supported_adapter!(PipelineCallbackJob)
          rescue ConfigurationError => error
            # Raising here would roll back a locked terminal settlement, the
            # worse outcome. The bundle is recorded as dispatched; the loss is
            # loud in the logs.
            Rails.logger.error("[GoodPipeline] callbacks for pipeline #{pipeline.id} not dispatched: #{error.message}")
            return
          end

          PipelineCallbackJob.set(queue: callback_queue_for(pipeline)).perform_later(pipeline.id, new_status.to_s)
        end
      end

      private

      # A missing pipeline class must not roll back a locked terminal
      # settlement; fall back to the global queue and let the callback job
      # surface the missing class as its own error.
      def callback_queue_for(pipeline)
        pipeline.type.constantize.callback_queue_name
      rescue NameError
        GoodPipeline.callback_queue_name
      end

      # A single conditional UPDATE decides the winner, so concurrent cancels
      # (a double-clicked button, two operators) settle on one canceled_at.
      # Runs inside cancel_pipeline's transaction; the UPDATE takes the pipeline
      # row lock, preserving the global pipeline→step lock order.
      def claim_cancellation(pipeline) # rubocop:disable Naming/PredicateMethod
        rows = PipelineRecord.where(id: pipeline.id, status: "running", canceled_at: nil)
                             .update_all(canceled_at: Time.current, updated_at: Time.current)
        return false if rows.zero?

        StepRecord.where(pipeline_id: pipeline.id, coordination_status: "pending")
                  .update_all(coordination_status: "skipped", updated_at: Time.current)
        true
      end

      # Coordinated failure handling for a step whose enqueue attempt raised
      # ConfigurationError after its savepoint rolled back. Locks are
      # re-acquired in pipeline→step order and the step is re-claimed
      # conditionally: the savepoint released its lock, so another actor (an
      # earlier failure's halt propagation, a concurrent cancel) may already
      # have resolved the step — in which case its state is left alone.
      # Returns [downstream_ids_to_cascade, pipeline_id_to_recompute_or_nil].
      def fail_step_for_configuration_error(step_id, error) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        pipeline_id = StepRecord.where(id: step_id).pick(:pipeline_id)
        return [[], nil] if pipeline_id.nil?

        claimed = false
        downstream_ids = []

        StepRecord.transaction do
          pipeline = PipelineRecord.lock("FOR UPDATE").find_by(id: pipeline_id)
          next if pipeline.nil?

          locked_step = StepRecord.lock("FOR UPDATE").find_by(id: step_id, coordination_status: "pending")
          next if locked_step.nil?

          claimed = true
          locked_step.update_columns(
            coordination_status: "failed",
            error_class: error.class.name,
            error_message: error.message,
            updated_at: Time.current
          )
          # The step reached a terminal state without passing through
          # complete_step, so its dependents' counts must be settled here —
          # otherwise an :ignore-strategy failure leaves a fan-in dependent
          # waiting on a decrement that no callback will ever deliver.
          decrement_upstream_counts_for_terminal_step(locked_step.id)
          propagate_halt(locked_step) if pipeline.halt?
          downstream_ids = locked_step.downstream_steps.pluck(:id)
        end

        [downstream_ids, claimed ? pipeline_id : nil]
      end

      # Cleanup can delete a terminal pipeline between the triggering event and
      # this re-read; a vanished row needs no settlement.
      def recompute_settled_pipeline(pipeline_id)
        pipeline = load_pipeline_with_active_check(pipeline_id)
        return if pipeline.nil?

        recompute_pipeline_status(pipeline, has_active_steps: pipeline["has_active_steps"])
      end

      def record_step_outcome(step, succeeded)
        if succeeded
          step.transition_coordination_status_to!(:succeeded)
        else
          record_step_failure(step)
        end
      end

      def record_step_failure(step)
        metadata = FailureMetadata.extract(step)
        step.update_columns(
          coordination_status: "failed",
          updated_at: Time.current,
          error_class: metadata.error_class,
          error_message: metadata.error_message,
          attempts: metadata.attempts
        )
      end

      def propagate_halt(step)
        exempt_ids = []

        StepRecord.transaction do
          step.pipeline.update_column(:halt_triggered, true)
          exempt_ids = skip_all_pending_steps(step.pipeline, except_dependents_of: step)
        end

        # An exempted step can also depend on a step outside the cone that the
        # mass skip just resolved negatively — no callback will ever revisit
        # it, so each survivor is re-evaluated here (still under the caller's
        # pipeline lock): skipped when an upstream became permanently
        # unsatisfied, enqueued when the failed :ignore upstream was the last
        # thing it was waiting on.
        exempt_ids.each { |id| try_enqueue_step(id) }
      end

      # Skips every pending step except the :ignore cone's survivors, and
      # returns those survivors' ids so the caller can re-evaluate them.
      def skip_all_pending_steps(pipeline, except_dependents_of:)
        scope = pipeline.steps.pending
        exempt_ids = []

        if effective_failure_strategy(except_dependents_of) == :ignore
          cone_ids = transitive_downstream_ids(except_dependents_of)
          exempt_ids = scope.where(id: cone_ids.to_a).pluck(:id) if cone_ids.any?
          scope = scope.where.not(id: exempt_ids) if exempt_ids.any?
        end

        scope.update_all(coordination_status: "skipped")
        exempt_ids
      end

      def transitive_downstream_ids(step)
        visited = Set.new
        queue = step.downstream_steps.pluck(:id)
        while (current_id = queue.shift)
          next if visited.include?(current_id)

          visited << current_id
          queue.concat(DependencyRecord.where(depends_on_step_id: current_id).pluck(:step_id))
        end
        visited
      end

      def unblock_downstream_steps(step)
        sql = <<~SQL
          UPDATE good_pipeline_steps
             SET pending_upstream_count = pending_upstream_count - 1
          WHERE id IN (
            SELECT step_id FROM good_pipeline_dependencies
             WHERE depends_on_step_id = $1
          )
            AND coordination_status = 'pending'
          RETURNING id, pending_upstream_count
        SQL

        any_enqueued = false
        StepRecord.connection.exec_query(sql, "SQL", [step.id]).each do |row|
          any_enqueued = true if row["pending_upstream_count"].zero? && try_enqueue_step(row["id"])
        end
        any_enqueued
      end

      def load_pipeline_with_active_check(pipeline_id)
        sql = <<~SQL.squish
          good_pipeline_pipelines.*,
          EXISTS(
            SELECT 1 FROM good_pipeline_steps
             WHERE pipeline_id = good_pipeline_pipelines.id
               AND coordination_status IN ('pending', 'enqueued')
          ) AS has_active_steps
        SQL

        PipelineRecord.select(sql).where(id: pipeline_id).first
      end

      def resolve_step(locked_step) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        if should_skip?(locked_step)
          locked_step.transition_coordination_status_to!(:skipped)
          decrement_upstream_counts_for_terminal_step(locked_step.id)
          locked_step.downstream_steps.pluck(:id)
        elsif locked_step.branch_step? && all_upstreams_satisfied?(locked_step)
          BranchResolver.resolve(locked_step)
          decrement_upstream_counts_for_terminal_step(locked_step.id)
          locked_step.downstream_steps.pluck(:id)
        elsif BranchResolver.skipped_by_branch?(locked_step)
          locked_step.transition_coordination_status_to!(:skipped_by_branch)
          decrement_upstream_counts_for_terminal_step(locked_step.id)
          locked_step.downstream_steps.pluck(:id)
        else
          enqueue_user_job(locked_step) if all_upstreams_satisfied?(locked_step)
          nil
        end
      end

      def should_skip?(step)
        step.pending? && step.upstream_steps.any? { |upstream| permanently_unsatisfied?(upstream) }
      end

      def permanently_unsatisfied?(upstream)
        upstream.terminal_coordination_status? &&
          !upstream.succeeded? &&
          !upstream.halted? &&
          !upstream.skipped_by_branch? &&
          effective_failure_strategy(upstream) != :ignore
      end

      def decrement_upstream_counts_for_terminal_step(step_id)
        downstream_ids = DependencyRecord.where(depends_on_step_id: step_id).select(:step_id)
        StepRecord.where(id: downstream_ids, coordination_status: "pending")
                  .update_all("pending_upstream_count = pending_upstream_count - 1")
      end

      def all_upstreams_satisfied?(step)
        step.upstream_steps.all? do |upstream|
          upstream.succeeded? ||
            upstream.halted? ||
            upstream.skipped_by_branch? ||
            (upstream.failed? && effective_failure_strategy(upstream) == :ignore)
        end
      end

      def enqueue_user_job(step)
        batch = build_step_batch(step)
        good_job_id = nil
        batch.enqueue { good_job_id = enqueue_step_job(step) }
        step.update_columns(
          coordination_status: "enqueued",
          good_job_batch_id: batch.id,
          good_job_id: good_job_id,
          updated_at: Time.current
        )
      end

      def build_step_batch(step)
        batch = GoodJob::Batch.new
        batch.on_finish = "GoodPipeline::StepFinishedJob"
        batch.callback_queue_name = constantize_for_step!(step.pipeline.type).coordination_queue_name
        batch.properties = { step_id: step.id }
        batch
      end

      def enqueue_step_job(step)
        job_class = constantize_for_step!(step.job_class)
        ensure_supported_adapter!(job_class)
        ensure_supported_adapter!(StepFinishedJob)
        job = job_class.new(**step.params.symbolize_keys)
        enqueued_job = job.enqueue(**step.enqueue_options.symbolize_keys)
        enqueued_job.provider_job_id || enqueued_job.job_id
      end

      # The boot check covers global configuration; this validates the
      # effective adapter at the enqueue boundary, catching per-job-class
      # adapter overrides and post-boot configuration changes. A non-GoodJob
      # adapter bypasses batch coordination entirely (the batch finishes empty
      # while the job escapes unbatched); inline execution runs the job during
      # enqueue, before coordination writes exist; async execution with neither
      # polling nor LISTEN/NOTIFY strands transactionally enqueued work after a
      # pre-commit wakeup miss; deferred enqueue loses the batch context.
      def ensure_supported_adapter!(job_class) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        adapter = job_class.queue_adapter

        unless adapter.is_a?(GoodJob::Adapter)
          raise ConfigurationError,
                "#{job_class} uses #{adapter.class}; GoodPipeline requires a GoodJob adapter — " \
                "other adapters bypass batch coordination entirely"
        end

        if adapter.execute_inline?
          raise ConfigurationError,
                "#{job_class} uses GoodJob's :inline execution mode, which GoodPipeline does not support"
        end

        if adapter.execute_async? && GoodJob.configuration.poll_interval.to_i <= 0 &&
           !GoodJob.configuration.enable_listen_notify
          raise ConfigurationError,
                "#{job_class} executes async with neither polling (poll_interval > 0) nor " \
                "LISTEN/NOTIFY (enable_listen_notify); a pre-commit wakeup miss would strand " \
                "transactionally enqueued work with nothing left to recover it"
        end

        return unless defers_enqueue_past_commit?(job_class, adapter)

        raise ConfigurationError,
              "#{job_class} defers enqueue until after commit, which loses GoodJob batch context; " \
              "GoodPipeline requires immediate enqueue"
      end

      # Mirrors Active Job's version-specific reading of the per-class
      # enqueue_after_transaction_commit attribute. 7.2: :always defers,
      # :never does not, anything else consults the adapter. 8.0: :always
      # defers, :never/:default do not (adapter consultation removed), other
      # values by truthiness. 8.1+: plain truthiness for every value — lingering
      # legacy symbols such as :never are truthy and therefore defer.
      # gem_version is injectable so the mapping is table-testable on any
      # installed Rails.
      def defers_enqueue_past_commit?(job_class, adapter, gem_version: ActiveJob.gem_version) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        setting = if job_class.respond_to?(:enqueue_after_transaction_commit)
                    job_class.enqueue_after_transaction_commit
                  else
                    :default
                  end

        if gem_version >= Gem::Version.new("8.1")
          setting ? true : false
        elsif gem_version >= Gem::Version.new("8.0")
          case setting
          when :always then true
          when :never, :default then false
          else setting ? true : false
          end
        else
          case setting
          when :always then true
          when :never then false
          else adapter.respond_to?(:enqueue_after_transaction_commit?) && adapter.enqueue_after_transaction_commit?
          end
        end
      end

      # Class names on pipeline and step rows outlive the code that defined
      # them. A resolution failure becomes ConfigurationError so the
      # coordinated failure handler records it on the step — instead of the
      # NameError killing StepFinishedJob (which has no retry policy) and
      # wedging the pipeline in `running`. Only the lookup itself is rescued:
      # a NameError raised from inside user code must not masquerade as a
      # missing class.
      def constantize_for_step!(class_name)
        class_name.constantize
      rescue NameError => error
        raise ConfigurationError, error.message
      end

      def derive_terminal_status(pipeline)
        # A canceled pipeline settles on `halted` whether or not any step
        # failed; without this it would derive `succeeded` from the absence of
        # failures, reporting a cancellation as a clean run.
        return :halted if pipeline.canceled_at?

        has_failures = pipeline.steps.where(coordination_status: "failed").exists?

        return :succeeded unless has_failures
        return :halted if pipeline.halt_triggered?

        :failed
      end

      # Branch roots cannot go through the bulk path — resolve_step's branch
      # checks have to run — but the bare try_enqueue_step takes a step lock
      # without a pipeline lock, which inverts the global pipeline→step order.
      # Against claim_cancellation (pipeline row, then pending steps in scan
      # order) that inversion is a real cycle: Pipeline#branch emits a branch's
      # arms before the branch step itself, so cancel reaches an arm first and
      # blocks on the branch step while try_enqueue_step holds the branch step
      # and reaches for the arms. Taking the pipeline row first serialises the
      # two, matching what bulk_enqueue_user_jobs and complete_step already do.
      def enqueue_branch_steps(pipeline_id, branch_steps)
        return if branch_steps.empty?

        StepRecord.transaction do
          pipeline = PipelineRecord.lock("FOR UPDATE").find_by(id: pipeline_id)
          next if pipeline.nil? || !pipeline.running? || pipeline.canceled?

          branch_steps.each { |step| try_enqueue_step(step.id) }
        end
      end

      def bulk_enqueue_user_jobs(steps) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        failed_steps = []
        coordination_queue = nil

        begin
          # Batch.enqueue_all consults the global adapter, and StepFinishedJob
          # is what every step batch enqueues on finish — both validated before
          # anything is resolved, so a failure here reliably prevents enqueue.
          ensure_supported_adapter!(ActiveJob::Base)
          ensure_supported_adapter!(StepFinishedJob)
          coordination_queue = constantize_for_step!(steps.first.pipeline.type).coordination_queue_name
        rescue ConfigurationError => error
          coordination_queue = nil
          failed_steps = steps.map { |step| [step, error] }
        end

        if coordination_queue
          StepRecord.transaction do # rubocop:disable Metrics/BlockLength
            # Root enqueue races the creation transaction's commit: Runner
            # enqueues after committing, so a cancel can arrive first, skip the
            # roots and settle the pipeline; and an in-flight try_enqueue_step
            # holds an uncommitted step lock that an unlocked re-select cannot
            # see. Locking the pipeline row, checking its state fresh, and
            # re-selecting the steps FOR UPDATE makes the outcome serial:
            # concurrent actors either already resolved the steps (excluded
            # here) or wait until these jobs exist and handle them normally.
            pipeline = PipelineRecord.lock("FOR UPDATE").find_by(id: steps.first.pipeline_id)
            next if pipeline.nil? || !pipeline.running? || pipeline.canceled?

            live_steps = StepRecord.lock("FOR UPDATE")
                                   .where(id: steps.map(&:id), coordination_status: "pending", good_job_id: nil)
                                   .order(:id)
                                   .to_a

            batch_job_pairs = []
            step_metadata = {}

            live_steps.each do |step|
              job_class = begin
                klass = constantize_for_step!(step.job_class)
                ensure_supported_adapter!(klass)
                klass
              rescue ConfigurationError => error
                failed_steps << [step, error]
                next
              end

              batch = GoodJob::Batch.new
              batch.on_finish = "GoodPipeline::StepFinishedJob"
              batch.callback_queue_name = coordination_queue
              batch.properties = { step_id: step.id }

              active_job = job_class.new(**step.params.symbolize_keys)
              apply_enqueue_options(active_job, step.enqueue_options.symbolize_keys)

              batch_job_pairs << [batch, [active_job]]
              step_metadata[step.id] = { batch: batch, active_job: active_job }
            end

            GoodJob::Batch.enqueue_all(batch_job_pairs) if batch_job_pairs.any?

            now = Time.current
            step_metadata.each do |step_id, metadata|
              StepRecord.where(id: step_id).update_all(
                coordination_status: "enqueued",
                good_job_batch_id: metadata[:batch].id,
                good_job_id: metadata[:active_job].provider_job_id || metadata[:active_job].job_id,
                updated_at: now
              )
            end
          end
        end

        handle_bulk_configuration_failures(failed_steps)
      end

      # Bulk failures produce no StepFinishedJob callback, so beyond the
      # coordinated per-step handling this must cascade skips to dependents and
      # explicitly recompute — otherwise a pipeline whose only remaining work
      # failed configuration would stay `running` forever.
      def handle_bulk_configuration_failures(failed_steps)
        return if failed_steps.empty?

        cascade_ids = []
        pipeline_ids = []

        failed_steps.each do |step, error|
          downstream_ids, pipeline_id = fail_step_for_configuration_error(step.id, error)
          cascade_ids.concat(downstream_ids)
          pipeline_ids << pipeline_id if pipeline_id
        end

        cascade_ids.each { |id| try_enqueue_step(id) }
        pipeline_ids.uniq.each { |id| recompute_settled_pipeline(id) }
      end

      def apply_enqueue_options(active_job, options) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return if options.blank?

        if options[:good_job_labels] && active_job.respond_to?(:good_job_labels=)
          active_job.good_job_labels = Array(options[:good_job_labels])
        end

        if options.key?(:good_job_notify) && active_job.respond_to?(:good_job_notify=)
          active_job.good_job_notify = options[:good_job_notify]
        end

        active_job.queue_name = options[:queue].to_s if options[:queue]
        active_job.priority = options[:priority] if options[:priority]
        active_job.scheduled_at = Time.current + options[:wait] if options[:wait]
      end

      def effective_failure_strategy(step)
        step.on_failure_strategy&.to_sym || step.pipeline.on_failure_strategy.to_sym
      end
    end
  end
end
