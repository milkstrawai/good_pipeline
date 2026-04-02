## [Unreleased]

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
