## [Unreleased]

### Added

- **Conditional branching** — `branch` DSL verb with `on` arms for runtime decision-making. The `by:` option names a method that returns which arm to execute. Non-matching arms are `skipped_by_branch` (satisfied for downstream).
- **Empty arms** — `on :skip` without a block for if-without-else patterns. Empty arms draw direct edges to the next step in the dashboard.
- **Multiple steps per arm** — arms can contain multiple `run` calls with intra-arm `after:` dependencies.
- **Interactive diagrams** — zoom (buttons + mouse wheel), click-drag pan, and fullscreen toggle on pipeline DAG visualizations.
- **Terminal "End" node** — all DAG diagrams now show an End node connecting from terminal steps, giving every diagram a clear finish point.
- **`skipped_by_branch` status** — new terminal coordination status that counts as satisfied for downstream dependency resolution, distinct from failure-based `skipped`.
- **`branch` JSONB column** — stores all branch metadata (`decides`, `branch_result`, `branch_key`, `branch_arm`, `empty_arms`) via `store_accessor` on a single column on the steps table.
- **Database indexes** — added index on `coordination_status` (steps) and a unique index on chains.

### Changed

- **`enqueue_options` column** — replaced separate `queue` and `priority` columns with a single `enqueue_options` JSONB column. Supports `queue`, `priority`, `wait`, `good_job_labels`, and `good_job_notify`.

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
