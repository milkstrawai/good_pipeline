## [Unreleased]

### Added

- **Pipeline phase barriers** — the new zero-argument `barrier` DSL verb inserts a persisted structural synchronization step between declaration phases. Prior phase exits converge on one barrier and following phase entries fan out from it, avoiding all-to-all dependency expansion. Barriers resolve synchronously without enqueuing an ActiveJob and appear as structural nodes in the dashboard.
- **Graceful dashboard cancellation** — administrators can stop future DAG scheduling without terminating already-enqueued, scheduled, or retrying GoodJob work; pipelines remain `canceling` until that work drains, then become terminal `canceled`.
- **Standalone dashboard re-runs** — administrators can start a fresh execution of a terminal pipeline from its stored parameters and current class definition. The original execution remains unchanged, and historical pipeline-chain relationships are not copied.
- **Read-only dashboard default** — pipeline mutation controls are hidden and rejected with `403 Forbidden` unless `GoodPipeline.dashboard_mutations_enabled = true` is configured explicitly. This setting does not replace authentication for the dashboard mount.
- **Redesigned dashboard** — a responsive execution shell with pipeline-type navigation, composable status/time/search filters, offset pagination, KPIs, expandable execution rows, stage timelines, and dedicated execution and definition views.
- **Persistent light and dark themes** — the dashboard now owns an isolated `data-gp-theme` attribute and persists the topbar toggle through a mount-aware Rails endpoint. Dark is now the default theme; existing users will see the dashboard change from light to dark after upgrading unless they select light.
- **Scale-aware graph views** — large DAGs default to aggregated stage views, with full Mermaid rendering available up to a 1,000-edge safety limit.
- **Dashboard upgrade generator** — `good_pipeline:upgrade` creates the three concurrent indexes used by type, status, and chronological dashboard queries, and safely no-ops when that migration already exists.
- **Rails compatibility matrix** — CI now exercises the Rails 7.2 support floor and the Rails 8.0 and 8.1 lines through Appraisal gemfiles.

### Breaking changes

- **Coordinator activity hints removed** — `Coordinator.recompute_pipeline_status` no longer accepts `has_active_steps:` or `has_downstream_chains:`. Terminal status is always derived from fresh rows while the pipeline is locked; obsolete callers now fail loudly instead of having their hints ignored.
- **Bulk enqueue contract tightened** — `Coordinator.bulk_enqueue_steps` raises `ArgumentError` when existing step IDs span multiple pipelines and now consistently returns `nil`. Both bulk and single-step enqueue refuse to schedule work unless the owning pipeline is `running`; `Coordinator.try_enqueue_step` reports that refusal as `false`.
- **Rails 7.2 minimum** — Rails 7.1 is no longer supported. Rails 7.1 [reached upstream end-of-life in October 2025](https://rubyonrails.org/2025/10/29/new-rails-releases-and-end-of-support-announcement) and no longer receives bug fixes or security fixes.

### Changed

- **Universal dependency normalization** — repeated keys in every `after:` list are deduplicated before validation and persistence, keeping dependency rows consistent with `pending_upstream_count` for pipelines with or without barriers.
- **Terminal edge-release invariant** — enqueue-time configuration failures and steps skipped by partial `:halt` propagation now release downstream dependency counters before eligible descendants are resolved. Terminalization, counter release, and downstream scheduling remain in one pipeline-locked transaction.
- **Pipeline-first coordination** — cancellation, completion, single enqueue, bulk enqueue, and status recomputation serialize on the owning pipeline row and then lock step rows in a consistent order. User jobs still execute concurrently; only coordination for the same pipeline is serialized, including downstream resolution and transactional GoodJob insertion.
- **Fresh terminal derivation** — completion and explicit status recomputation derive running/canceling outcomes through one locked path. A redelivered terminal step also recomputes a nonterminal pipeline, repairing stale terminal status left by older coordinator versions or manual intervention.
- **Post-commit chain handoff** — terminal chain propagation runs after all surrounding transactions commit, avoiding cross-pipeline lock nesting and making `GoodPipeline.run` safe inside a caller-managed transaction.
- **Step completion ownership metadata** — new step batches record their `pipeline_id`, avoiding an ownership lookup before completion locking. `StepFinishedJob` falls back to the step row for batches queued before this upgrade.
- **Callback delivery semantics clarified** — `callbacks_dispatched_at` guarantees one transactional callback-job enqueue, not exactly-once user callback execution. Retry behavior remains application-configured, and callbacks should be idempotent.
- **Execution pagination** — dashboard lists now use clamped offset pagination with a total page count instead of keyset cursors.
- **Step timings** — dashboard timing data is batch-loaded from GoodJob, removing per-step lookups while preserving the same retention boundary as job records.
- **Relative timestamps** — times under one minute now render as exact seconds such as `30s ago` instead of `just now`.
- **Dashboard dependencies** — versioned dashboard CSS and JavaScript ship with the gem; graph rendering remains build-free and is initialized client-side in strict mode.

### Fixed

- **All-empty branch continuation** — a branch whose arms are all empty now aliases to its structural sentinel, so `after: :branch_key` remains ordered after the branch decision with or without a preceding barrier.
- **Multiple ignored halt failures** — bulk enqueue-time failures that all override pipeline-level `:halt` with `:ignore` now protect the union of their downstream subtrees instead of allowing each halt pass to skip another ignored subtree.
- **Skipped dependencies under inherited ignore** — ordinary `skipped` and `canceled` steps are always treated as permanently unsatisfied, preventing descendants from remaining pending when a skipped step inherits pipeline-level `:ignore`.
- **Dropped chain fan-in wake-ups** — `ChainCoordinator` now waits on a blocking `FOR UPDATE` lock instead of silently skipping a contended downstream pipeline with `SKIP LOCKED`.
- **Database benchmark pipeline resolution** — dynamically generated benchmark pipeline classes are now registered as constants, allowing the enqueue, completion, recomputation, halt, and full-run sections of `bench/database_bench.rb` to execute.

### Upgrade notes

- Barrier-aware deployments require two phases: first deploy this gem version to every web and worker process capable of running coordinator code; only after all old processes have stopped should application code using `barrier` be deployed. Older coordinators treat the new structural sentinel as an executable job class and cannot safely process barrier definitions.
- Existing dashboard mounts remain read-only after upgrading. Protect the engine mount with administrator authentication, then set `GoodPipeline.dashboard_mutations_enabled = true` to expose dashboard mutation controls, including cancellation and re-running terminal pipelines. The theme preference remains available in read-only mode.
- Coordinator completion and enqueue operations for one pipeline are now serialized for cancellation correctness. Wide fan-in increases coordination query volume because every upstream completion locks and recomputes pipeline state; many concurrent completions, such as leaves in a wide fan-out, can contend on the pipeline row. Recursive fan-out scheduling reuses that lock and issues fewer queries than before.
- Run `bin/rails generate good_pipeline:upgrade` and `bin/rails db:migrate` to add the dashboard indexes. See `docs/dashboard.md` for recovery steps if a concurrent index build is interrupted.
- GoodJob may remove timing rows for early steps of a still-running pipeline; those steps render `—` rather than raising or issuing individual lookups.

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

- **Late `.then` registrations no longer strand downstream pipelines** — if `.then` is called after the upstream pipeline has already reached a terminal state, the chain coordinator now immediately propagates that state.
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
