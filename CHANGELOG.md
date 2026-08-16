## [0.5.0] - 2026-08-11

### Added

- **Redesigned dashboard** — a responsive execution shell with pipeline-type navigation, composable status/time/search filters, offset pagination, KPIs, expandable execution rows, stage timelines, and dedicated execution and definition views.
- **Persistent light and dark themes** — the dashboard now owns an isolated `data-gp-theme` attribute and persists the topbar toggle through a mount-aware Rails endpoint. Dark is now the default theme; existing users will see the dashboard change from light to dark after upgrading unless they select light.
- **Scale-aware graph views** — large DAGs default to aggregated stage views, with full Mermaid rendering available up to a 1,000-edge safety limit.
- **Cancel execution** — the dashboard's cancel button is live. Cancelling drains rather than kills: pending steps are skipped immediately, steps already handed to a GoodJob worker run to completion, and the pipeline settles on `halted` once the last of them reports back. The claim and the settlement share one transaction, so a cancel cannot half-apply. Available through `GoodPipeline::Coordinator.cancel_pipeline(pipeline)` outside the dashboard.
- **Re-run execution** — the dashboard's re-run button is live, and behaves the same for every status. It starts a new execution from the stored type and params and redirects to it, leaving the original in place as history. Stored params that no longer match the pipeline's `configure` signature report back as a flash rather than raising; if an unexpected startup error occurs after graph persistence, the response redirects to the newly created execution rather than hiding it behind the source run.
- **Dashboard upgrade generator** — `good_pipeline:upgrade` creates the three concurrent indexes used by type, status, and chronological dashboard queries plus the `canceled_at` column, skipping either migration when a file for it already exists.
- **Rails compatibility matrix** — CI now exercises the Rails 7.2 support floor and the Rails 8.0 and 8.1 lines through Appraisal gemfiles.

### Breaking changes

- **Rails 7.2 minimum** — Rails 7.1 is no longer supported. Rails 7.1 [reached upstream end-of-life in October 2025](https://rubyonrails.org/2025/10/29/new-rails-releases-and-end-of-support-announcement) and no longer receives bug fixes or security fixes.
- **Unsupported execution configurations are rejected at boot and at every enqueue boundary.** GoodPipeline needs a job to be handed to a worker through the database, not executed during enqueue, and it needs a durable wakeup for work enqueued inside a transaction. `ConfigurationError` is now raised for three configurations:
  - **`:inline`.** A step's job runs before its coordination row is stamped, so `halt_pipeline!` is silently discarded (`Haltable` resolves the step by `good_job_id`, which is not yet written), a failing step aborts its remaining siblings with no worker to recover them, and steps enqueued with a delay — including any `retry_on` backoff, which defaults to 3 seconds — never run at all. Note this is keyed on the **effective adapter**, not on `GoodJob.configuration.execution_mode`: GoodJob reports `:inline` for any application that leaves the mode unset under `Rails.env.test?`, and an application on Active Job's `:test` adapter is not executing anything inline.
  - **Effective deferred enqueue.** Deferring the enqueue past commit loses batch context and breaks the atomic chain handoff. The check follows Active Job's actual per-class semantics rather than rejecting the raw GoodJob adapter setting: Rails 7.2 consults the adapter for `:default`, Rails 8.0 treats `:default` as immediate, and Rails 8.1 uses truthiness.
  - **Effective async execution without positive polling.** A job enqueued inside a transaction can wake the in-process worker before commit; that thread finds nothing, and because it was created GoodJob suppresses the `NOTIFY`. LISTEN/NOTIFY therefore cannot recover this miss by itself. Every effectively in-process async adapter requires `poll_interval > 0`; `:async`/`:async_server` behaving as `:external` outside a webserver do not.

  Every enqueue boundary additionally validates the effective adapter: it must be a GoodJob adapter (other adapters, including Active Job's own `:inline` and `:test`, bypass batch coordination entirely — the batch finishes empty while the job escapes unbatched), and it must not defer enqueue, including per-job-class `enqueue_after_transaction_commit` overrides interpreted per Rails version (7.2 symbols with adapter consultation; 8.0 symbols without; 8.1+ plain truthiness, where lingering legacy symbols like `:never` are truthy and defer).

### Fixed

- **Settlement is now serialized and chain propagation is durable** — terminal derivation, the status transition, callback reservation, and one `ChainPropagationJob` per outgoing edge happen under `FOR UPDATE` in one database transaction. A crash immediately after commit cannot lose the handoff; delivery is at least once and the downstream's locked pending transition makes duplicates harmless.
- **Concurrent chain fan-in and late registration no longer strand downstreams** — propagation blocks on the downstream row, while `.then` locks all upstream rows in primary-key order before it commits incoming edges and schedules already-terminal upstreams. Settlement and registration therefore form a lock-based handshake across every interleaving. Per-edge jobs isolate retries so one downstream cannot starve another.
- **Step completion is claimed atomically** — `StepFinishedJob` outcomes are applied only when the step is still `enqueued` and owned by the reporting batch. Duplicate callback deliveries and GoodJob-UI batch retries of an old attempt are ignored instead of overwriting a newer attempt's state, and halt policy now commits atomically with the step outcome (fixing a race that could settle a `:halt` failure as `failed` instead of `halted`).
- **Missing classes and deterministic start failures fail steps instead of wedging pipelines** — deleted class names, constructor/argument/serialization failures, invalid enqueue options, and branch-decision exceptions are recorded on the affected step with their original class and message. Dependency counts, failure strategy, skip propagation, and terminal recomputation then run normally. Database and GoodJob persistence failures remain infrastructure errors and retain the created pipeline id through `PipelineStartError`.
- **Steps that fail without a callback settle their dependents' upstream counts** — a configuration failure reaches a terminal state with no `StepFinishedJob` to report it, so the failure site now decrements dependents' counts itself. Previously an `:ignore`-strategy configuration failure left a fan-in dependent waiting on a decrement that never arrived, wedging the pipeline in `running`. Halt propagation likewise re-evaluates surviving `:ignore`-cone steps after the mass skip, so a survivor blocked by a skipped outside arm is now skipped instead of stranded.
- **A redelivered step callback re-derives settlement** — a crash between a step outcome committing and the settlement recompute previously left the pipeline `running` with nothing to advance it: the redelivered callback found its claim already consumed and returned early. An unclaimed delivery now recomputes pipeline status, which is idempotent, so genuinely stale callbacks still change nothing.
- **Cleanup is transactional and chain-safe** — candidates are re-checked under ordered `FOR UPDATE SKIP LOCKED`, and terminal upstreams referenced by pending downstreams are preserved until durable propagation consumes the relationship.
- **Root enqueue is serialized against cancellation and single-step enqueue** — the pipeline is created and committed before its roots are enqueued, so a cancel could land in that window, skip the roots and settle the pipeline, after which the bulk path stamped the skipped steps back to `enqueued` with live jobs on a terminal record; an in-flight single-step enqueue could also be double-enqueued. Bulk enqueue now locks the pipeline row, verifies it is still running and not canceled, and re-selects the steps under `FOR UPDATE` before creating any job. `bulk_enqueue_steps` now raises `ArgumentError` for step sets spanning multiple pipelines.
- **Branch roots no longer deadlock against a concurrent cancel** — a branch root takes the single-step enqueue path, which locked the step row without first locking the pipeline row, inverting the global pipeline→step lock order. Because `branch` emits a branch's arm steps before the branch step itself, cancel reached an arm first and waited on the branch step while the enqueue held the branch step and reached for the arms; PostgreSQL aborted one side and `ActiveRecord::Deadlocked` escaped `Pipeline.run`. Branch roots now take the pipeline row first.
- **Configuration validation now runs after GoodJob applies Rails configuration** — the boot check previously ran at `on_load(:active_job)`, which can fire before GoodJob's `good_job.rails_config` initializer applies `config.good_job.*`, so an application-configured `preserve_job_records = false` validated against defaults and booted broken.

### Changed

- **Execution pagination** — dashboard lists now use clamped offset pagination with a total page count instead of keyset cursors.
- **Step timings** — dashboard timing data is batch-loaded from GoodJob, removing per-step lookups while preserving the same retention boundary as job records.
- **Relative timestamps** — times under one minute now render as exact seconds such as `30s ago` instead of `just now`.
- **Dashboard dependencies** — versioned dashboard CSS and JavaScript ship with the gem; graph rendering remains build-free and is initialized client-side in strict mode.
- **Re-run replaces "retry failed step"** — the action bar previously offered "retry failed step" for failed and halted executions. Re-running is not a resumption: every step runs again, including steps that already succeeded, so the label is now "re-run pipeline".

### Upgrade notes

- Run `bin/rails generate good_pipeline:upgrade` and `bin/rails db:migrate`. This adds the dashboard indexes and the nullable `canceled_at` column. The column is **required** for this release, not merely when cancel is clicked: every execution view reads it and settlement consults it. New installs get both from the install generator. See `docs/dashboard.md` for recovery steps if a concurrent index build is interrupted.
- **Two GoodJob defaults need attention.** GoodJob defaults the **test** environment to `execution_mode :inline`; set `config.good_job.execution_mode = :external` and drain with `GoodJob.perform_inline`. Its development async default can use `poll_interval = -1`, which disables the only recovery path for a suppressed pre-commit wakeup; set a positive interval (for example GoodJob's normal `10` seconds) even when LISTEN/NOTIFY is enabled.
- **Tests that create pipelines must use a GoodJob adapter.** Active Job's `:test` adapter bypasses batch coordination entirely, so the enqueue guard rejects it: root steps are recorded `failed` with a `ConfigurationError` and the pipeline settles `failed` — `perform_enqueued_jobs` never sees pipeline work. Note that `ActiveJob::TestHelper` installs its own test adapter on `ActiveJob::Base` inside every `ActiveJob::TestCase`, so pipeline tests need to sit outside it.
- A canceled pipeline reports the existing `halted` status rather than a new one, so status filters, badges and KPI queries need no changes. `canceled_at` distinguishes an operator cancel from a failure-driven halt, and the dashboard renders it as `halted · canceled`.
- Cancelling dispatches `on_complete` and `on_failure` callbacks the same way any other halt does.
- Re-running does not recreate pipelines chained onto the original with `.then`, because that topology lives at the original call site rather than in the pipeline class. The confirm dialog states this.
- There is no in-place retry of a failed step. Retrying a step's batch from GoodJob's own dashboard re-runs the job, but the completion claim ignores the stale callback, so the pipeline does not advance from it; re-run is the supported recovery.

## [0.4.0] - 2026-04-02

### Performance

- **Bulk root step enqueuing** — pipelines with multiple root steps now enqueue all of them via `GoodJob::Batch.enqueue_all` in a fixed number of queries instead of ~9 queries per step. Both `Runner#enqueue_root_steps` and `ChainCoordinator#start_pipeline` use the new `Coordinator.bulk_enqueue_steps` method.

### Added

- **Configurable queue names for internal jobs** — new `coordination_queue_name` and `callback_queue_name` settings control which queues `StepFinishedJob`, `PipelineReconciliationJob`, and `PipelineCallbackJob` run on. Configurable globally (`GoodPipeline.coordination_queue_name = "x"`) and per-pipeline via the class DSL. Defaults to `"good_pipeline_coordination"` and `"good_pipeline_callbacks"`.
- **`Coordinator.bulk_enqueue_steps`** — public method that loads pending steps, partitions branch steps for individual handling, and bulk-enqueues the rest via `Batch.enqueue_all`. Invalid job classes are failed individually without blocking valid steps.

### Changed

- **Minimum GoodJob version** — bumped from `>= 3.10` to `>= 4.14` (required for `Batch.enqueue_all`).
- **`run_pipeline_to_completion` test helper** — extracted from 3 integration test files into `test_helper.rb`.

## [0.3.1] - 2026-03-26

### Added

- **`halt_pipeline!`** — call from any job to stop the pipeline early with a `succeeded` status. The halting step is marked `halted`, remaining pending steps are `skipped`, and the `on_success` callback fires. The GoodJob record completes as succeeded (no error, no discard). Available in all jobs via `GoodPipeline::Haltable`, included automatically by the Engine.
- **`halted` coordination status** — new terminal step status for steps that called `halt_pipeline!`. Treated as satisfied for downstream dependency resolution.
- **`halt_requested` column** — boolean column on steps table, set by `halt_pipeline!` and checked by the coordinator on step completion.
- **`good_job_id` index** — partial unique index on `good_job_id` for fast step lookup from within jobs.

## [0.3.0] - 2026-03-25

### Performance

- **Bulk insert steps and dependencies** — `Runner` uses `insert_all!` with `RETURNING` for steps and dependencies instead of individual `create!` calls, reducing pipeline creation from N+M queries to 2.
- **Pre-generated pipeline UUID** — `Runner` generates the pipeline UUID upfront, folding batch ID and initial status into a single INSERT instead of separate UPDATEs.
- **Atomic upstream counter** — new `pending_upstream_count` column on steps tracks how many upstreams remain. `unblock_downstream_steps` atomically decrements via `UPDATE ... RETURNING` and only calls `try_enqueue_step` when the count reaches zero, eliminating O(N) wasted lock acquisitions for fan-in and diamond topologies.
- **Merged UPDATE round-trips** — `enqueue_user_job` folds status transition, batch ID, and job ID into one `update_columns`. `record_step_failure` merges status and error metadata into one `update_columns`.
- **Removed redundant transaction** — `record_step_outcome` no longer wraps a single `update_columns` in an explicit transaction.
- **`update_columns` in transition methods** — `transition_coordination_status_to!` and `transition_to!` use `update_columns` instead of `update!`, skipping AR dirty tracking overhead.
- **SQL EXISTS for status checks** — `recompute_pipeline_status` and `derive_terminal_status` use `EXISTS` queries instead of loading all step records.
- **Pipeline load with EXISTS** — `load_pipeline_with_active_check` combines pipeline load with active-step and downstream-chain EXISTS checks in a single query.
- **Conditional callback dispatch** — `dispatch_callbacks_once` uses `UPDATE WHERE callbacks_dispatched_at IS NULL` instead of `SELECT FOR UPDATE` + `UPDATE`.
- **Early return on active pipeline** — `complete_step` skips pipeline status recomputation when `unblock_downstream_steps` enqueued any downstream step.
- **Bulk skip on halt** — `skip_all_pending_steps` uses `update_all` instead of iterating with individual updates.
- **Single-pass graph validation** — `GraphValidator` merges duplicate-key check, self-dependency check, steps-by-key index, and forward-edges construction into one O(n) pass and returns `steps_by_key` for reuse by `Pipeline`.
- **Frozen constant defaults** — `EMPTY_HASH` and `EMPTY_ARRAY` shared constants avoid allocating fresh empty containers on every `StepDefinition` and `Pipeline#run` call.
- **Fast-path shortcuts** — `validate_enqueue_options!` returns immediately for empty options. `expand_branch_aliases` skips `flat_map` when no branches are defined.

### Added

- **Benchmarking scripts** — `bench/memory_bench.rb` (in-memory, no DB) and `bench/database_bench.rb` (PostgreSQL) with `--json` flag for structured output. Covers pipeline construction, graph validation, cycle detection, step enqueue, step completion, status recomputation, halt propagation, and full pipeline run across linear, fan-out, fan-in, and diamond topologies.
- **`pending_upstream_count` column** — integer column on steps table, set by `Runner` at creation time, decremented atomically by `Coordinator` on step completion.

### Changed

- **`Runner` refactored** — `call` method extracted into `create_pipeline_batch`, `create_pipeline_record`, `insert_steps`, `insert_dependencies`, and `enqueue_root_steps` for readability. Pipeline record is a local variable passed to methods instead of an instance variable.
- **`Coordinator` method reordering** — private methods grouped by concern (outcome recording, downstream unblocking, step resolution, pipeline status) rather than call order.

## [0.2.2] - 2026-03-24

### Fixed

- **Fan-in step race condition** — replaced `FOR UPDATE SKIP LOCKED` with `FOR UPDATE` in `Coordinator.try_enqueue_step`. When multiple upstreams of a fan-in step completed simultaneously, `SKIP LOCKED` caused concurrent callers to silently give up, leaving the downstream step stranded in `pending` forever. Blocking locks ensure the last caller always sees all upstreams satisfied and enqueues the step. Existing `pending?` and `good_job_id` guards provide idempotency.

## [0.2.1] - 2026-03-24

### Fixed

- **`dependent: :destroy` on pipeline steps** — switched from `delete_all` to `destroy` so that destroying a pipeline properly triggers StepRecord's cascading cleanup of dependency records.
- **Redundant database indexes** — removed single-column indexes on `steps(pipeline_id)` and `chains(upstream_pipeline_id)` that were already covered by their respective composite indexes.

## [0.2.0] - 2026-03-24

### Added

- **Conditional branching** — `branch` DSL verb with `on` arms for runtime decision-making. The `by:` option names a method that returns which arm to execute. Non-matching arms are `skipped_by_branch` (satisfied for downstream). Decision results are validated against declared arms — undeclared results fail the branch step with a `ConfigurationError` and the pipeline reaches a terminal state through normal failure propagation.
- **Empty arms** — `on :skip` without a block for if-without-else patterns. Empty arms draw direct edges to the next step in the dashboard.
- **Sequential branches** — multiple `branch` calls in sequence, where each branch waits for the previous branch's chosen arm to complete before running its decision method.
- **Multiple steps per arm** — arms can contain multiple `run` calls with intra-arm `after:` dependencies.
- **Interactive diagrams** — zoom (buttons + mouse wheel), click-drag pan, and fullscreen toggle on pipeline DAG visualizations.
- **Terminal "End" node** — all DAG diagrams now show an End node connecting from terminal steps, giving every diagram a clear finish point.
- **`skipped_by_branch` status** — new terminal coordination status that counts as satisfied for downstream dependency resolution, distinct from failure-based `skipped`.
- **`branch` JSONB column** — stores all branch metadata (`decides`, `branch_result`, `branch_key`, `branch_arm`, `empty_arms`) via `store_accessor` on a single column on the steps table.
- **Database indexes** — added index on `coordination_status` (steps) and a unique index on chains.
- **Step-level failure strategy validation** — `StepDefinition` rejects invalid `on_failure:` values at definition time with a `ConfigurationError`.
- **`display_name`** — optional class-level DSL method to override how a pipeline appears on the dashboard. Falls back to the default `underscore.titleize` format when not set.

### Changed

- **`enqueue_options` column** — replaced separate `queue` and `priority` columns with a single `enqueue_options` JSONB column. Supports `queue`, `priority`, `wait`, `good_job_labels`, and `good_job_notify`.
- **`private_class_method` replaced with `class << self`** — `Coordinator`, `ChainCoordinator`, `CycleDetector`, and `FailureMetadata` now use `class << self` with `private` keyword instead of `private_class_method` lists at the bottom of each class.

### Fixed

- **Late `.then` registrations no longer strand downstream pipelines** — if `.then` is called after the upstream pipeline has already reached a terminal state, the chain coordinator schedules its evaluation. As of 0.5.0, that handoff is a durable GoodJob row committed with the new edge.
- **Step-level `:ignore` under `:halt` now protects the full downstream subgraph** — `skip_all_pending_steps` now computes the transitive closure of downstream steps (via BFS) instead of only exempting direct children. Previously, `A(ignore) -> B -> C` under `:halt` would preserve `B` but immediately skip `C`.

## [0.1.0] - 2026-03-20

### Added

- **Pipeline DSL** — `GoodPipeline::Pipeline` base class with `configure` method and `run` as the sole DSL verb
- **DAG validation** — cycle detection (three-color DFS), duplicate keys, unknown references, self-dependencies, and empty pipeline checks — all at instantiation time before any database writes
- **Three failure strategies** — `:halt` (default), `:continue`, and `:ignore` at pipeline level, with per-step `on_failure:` override
- **Coordinator** — sole owner of all `coordination_status` transitions with explicit transaction boundaries, `FOR UPDATE SKIP LOCKED` row locking, and `good_job_id` null guard to prevent double-enqueue
- **Atomic enqueue** — step status transition and GoodJob record insertion in a single Postgres transaction
- **Pipeline chaining** — `.then()` API for serial chains, fan-out, fan-in, and `GoodPipeline.run()` for parallel start
- **Lifecycle callbacks** — `on_complete`, `on_success`, `on_failure` with asynchronous dispatch via `PipelineCallbackJob` and exactly-once guarantee via `callbacks_dispatched_at` guard
- **Web dashboard** — mountable Rails engine with pipeline executions list (status tabs, type filter, keyset pagination), pipeline details page (steps table, Mermaid DAG visualization, chain links), and pipeline definitions catalog
- **Automatic cleanup** — subscribes to GoodJob's `cleanup_preserved_jobs` notification to delete terminal pipelines using the same retention period
- **Install generator** — `rails generate good_pipeline:install` creates migration for four tables (`good_pipeline_pipelines`, `good_pipeline_steps`, `good_pipeline_dependencies`, `good_pipeline_chains`)
