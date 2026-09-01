# Architecture

Internal architecture for contributors and anyone who wants to understand how the system works.

## Layer diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        DSL Layer                            │
│    Pipeline.configure defines and compiles DAG topology     │
│    Step keys are graph identity; job classes are impl       │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  Validation Layer                            │
│    DAG validated at instantiation time, before DB writes    │
│    Cycles, unknown keys, duplicates rejected upfront        │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                     State Layer                             │
│    Postgres tables are the authoritative source of truth    │
│    coordination_status is the sole input for decisions      │
│    halt_triggered flag drives :halted derivation            │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                   Execution Layer                            │
│    One GoodJob::Batch per executable step                   │
│    User jobs enqueued via perform_later — fully untouched   │
│    Batch on_finish is the sole terminal signal              │
│    Enqueue is transactionally coupled to row transition     │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  Coordination Layer                          │
│    Coordinator owns ALL coordination_status transitions     │
│    Pipeline-first FOR UPDATE locks serialize coordination    │
│    One transaction per coordination call; fresh state reads │
│    Running/canceling outcomes share one derivation path     │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                    Chain Layer                               │
│    .then() wires pipeline-level DAG dependencies            │
│    Same coordinator pattern, one level up                   │
└─────────────────────────────────────────────────────────────┘
```

## Data model

GoodPipeline uses four Postgres tables:

### `good_pipeline_pipelines`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | Primary key |
| `type` | string | Pipeline class name (e.g. `"VideoProcessingPipeline"`) |
| `params` | jsonb | Arguments passed to `.run()` |
| `status` | string | `pending`, `running`, `canceling`, `succeeded`, `failed`, `halted`, `skipped`, `canceled` |
| `halt_triggered` | boolean | Set to `true` when `:halt` strategy is applied |
| `good_job_batch_id` | uuid | Pipeline-level GoodJob::Batch for grouping |
| `on_failure_strategy` | string | `halt`, `continue`, or `ignore` |
| `callbacks_dispatched_at` | timestamp | Enqueue-once callback job guard |
| `created_at` | timestamp | |
| `updated_at` | timestamp | |

### `good_pipeline_steps`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | Primary key |
| `pipeline_id` | uuid | Foreign key |
| `key` | string | Step key — graph identity |
| `job_class` | string | ActiveJob class name or structural `GoodPipeline::Branch` / `GoodPipeline::Barrier` sentinel |
| `params` | jsonb | Arguments passed to `with:` |
| `coordination_status` | string | `pending`, `enqueued`, `succeeded`, `failed`, `skipped`, `skipped_by_branch`, `halted`, `canceled` |
| `on_failure_strategy` | string | Step-level override (nullable) |
| `enqueue_options` | jsonb | Options passed to `job.enqueue()` (queue, priority, wait, etc.) |
| `good_job_batch_id` | uuid | Step's own GoodJob::Batch |
| `good_job_id` | uuid | GoodJob record ID (nil until enqueued) |
| `attempts` | integer | Execution attempt count |
| `error_class` | string | Terminal failure error class |
| `error_message` | text | Terminal failure error message |
| `created_at` | timestamp | |
| `updated_at` | timestamp | |

Unique constraint: `(pipeline_id, key)` — enforces step key uniqueness within a pipeline.

### `good_pipeline_dependencies`

| Column | Type | Notes |
|---|---|---|
| `id` | bigint | Primary key |
| `pipeline_id` | uuid | Denormalized for fast querying |
| `step_id` | uuid | The dependent step |
| `depends_on_step_id` | uuid | The step that must complete first |

### `good_pipeline_chains`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | Primary key |
| `upstream_pipeline_id` | uuid | The pipeline that must finish first |
| `downstream_pipeline_id` | uuid | The pipeline to start after |

## One batch per executable step

Each executable step has its own `GoodJob::Batch`. The user's job is enqueued via `perform_later` into that batch, preserving all ActiveJob semantics (instrumentation, callbacks, serialization, queue routing, retries, `discard_on`). Structural branch and barrier steps are persisted for coordination and observability but are resolved synchronously without a GoodJob batch or job.

When the batch's `on_finish` fires, `StepFinishedJob` receives the signal and delegates to the coordinator. `StepFinishedJob` is a thin dispatcher — it does not own any state transitions.

## The coordinator

The `Coordinator` class is the sole owner of all `coordination_status` transitions. Its cancellation, completion, enqueue, and recompute entry points use one coordination transaction with a consistent pipeline-first lock order:

1. **Pipeline lock** — acquires a blocking `FOR UPDATE` lock on the owning pipeline
2. **Step locks** — acquires blocking `FOR UPDATE` locks on step rows only after the pipeline lock
3. **Coordination** — records the outcome, applies failure policy, resolves downstream enqueue, then derives pipeline status from fresh step rows before commit

Cancellation, single-step enqueue, bulk enqueue, and completion all follow this order. This serializes the cancellation barrier against new enqueue attempts: whichever transaction obtains the pipeline lock first completes its state change before the other rechecks the current pipeline status. User jobs execute outside these coordination transactions; only their GoodJob insertion is transactionally coupled to the step transition.

`pending_upstream_count` represents upstream edges whose source has not reached a terminal coordination status. Any terminal transition that leaves pending descendants eligible releases its outgoing edges exactly once inside the same transaction. The coordinator terminalizes all affected steps first, decrements all relevant counters second, and only then examines newly ready descendants. Full cancellation and unconditional halt may omit edge release because no pending descendant remains eligible.

### Barrier compilation and resolution

After `configure`, barrier markers divide user definitions into phases. The compiler validates the authored DAG, finds each phase's entries and exits from graph topology, inserts one structural barrier definition per boundary, and validates the compiled DAG. Generated edges are deduplicated before Runner persists dependency rows.

At runtime, the last terminal phase exit reduces the barrier's counter to zero. Under the pipeline lock, the coordinator marks the barrier `succeeded` when all exits are satisfied, or `skipped` when one is permanently unsatisfied, releases its outgoing edges, and recursively resolves the following phase. No worker thread waits and no no-op job is enqueued.

### Graceful cancellation

`Coordinator.cancel_pipeline` locks the pipeline before changing its state. A `pending` pipeline and its pending steps become `canceled` immediately. A `running` pipeline becomes `canceling`, and all of its still-pending steps become `canceled`, creating a scheduling barrier that prevents future downstream enqueue.

Cancellation deliberately does not alter GoodJob records or force-terminate workers. Jobs that are already enqueued, scheduled, or retrying run normally. Their steps retain the actual terminal outcome (`succeeded`, `failed`, or `halted`), while completion coordination suppresses normal failure propagation and downstream enqueue. When no enqueued steps remain, the pipeline becomes `canceled`; without polling or force termination, it may remain nonterminal `canceling` indefinitely if an enqueued job never finishes.

## Running and canceling outcome derivation

For a `running` or `canceling` pipeline, the terminal outcome is not inferred from one step event. `recompute_pipeline_status` reads fresh step `coordination_status` values and the `halt_triggered` flag while the pipeline is locked:

| Condition | Derived status |
|---|---|
| A `running` pipeline has any step `pending` or `enqueued` | Not terminal — still running |
| All steps terminal, none `failed` | `succeeded` |
| All steps terminal, at least one `failed`, `halt_triggered` is `true` | `halted` |
| All steps terminal, at least one `failed`, `halt_triggered` is `false` | `failed` |
| Pipeline is `canceling` and any step is still `enqueued` | Remain `canceling` — active and nonterminal |
| Pipeline is `canceling` and no step is `pending` or `enqueued` | `canceled` |

Cancellation takes precedence over failure-derived status: after a pipeline enters `canceling`, drained step outcomes remain available for inspection but the pipeline finishes as `canceled`. Recomputing is idempotent on terminal pipelines. A pending pipeline can instead transition directly to `canceled`, and chain propagation can transition a pending downstream pipeline directly to `skipped`; neither case needs step-outcome derivation.

## Enqueue transaction contract

The transition of a step from `pending` to `enqueued` and the insertion of the corresponding GoodJob record happen inside a **single database transaction**. This is possible because GoodJob stores jobs in Postgres — the same database as GoodPipeline's tables.

If the transaction rolls back, both the step status revert and the GoodJob record insertion are cancelled atomically. No stuck-enqueued steps, no ghost jobs.

## Concurrency safety

### Enqueue and cancellation races

If concurrent completions target a shared downstream step, or cancellation races an enqueue attempt, GoodPipeline prevents an invalid interleaving with:

1. **Pipeline-first serialization** — cancellation, completion, and enqueue paths take the owning pipeline's blocking `FOR UPDATE` lock first
2. **Blocking step locks** — downstream step rows are locked with `FOR UPDATE` in a consistent order after the pipeline lock
3. **Fresh guards** — pipeline status, step status, active-step existence, and `good_job_id` are rechecked while locked before enqueue or terminalization

### Callback dispatch guard

`dispatch_callbacks_once` conditionally updates only a pipeline whose `callbacks_dispatched_at` is still `NULL`. The winning update sets the timestamp and enqueues one callback job inside the terminal-state transaction; later attempts update zero rows. Callback job execution is not exactly once, so user callbacks must tolerate interruption, redelivery, or manual retry.

Chain propagation is registered with `ActiveRecord.after_all_transactions_commit`, so it never acquires downstream pipeline locks while an upstream or caller-managed transaction is still open. The propagation operation is idempotent, but its post-commit delivery is not a durable outbox; crash-safe chain delivery is a separate reliability concern.

## Retry model

GoodPipeline never inspects exceptions during retry attempts. It only responds to the **terminal signal** from the step batch's `on_finish` callback:

| GoodJob outcome | GoodPipeline response |
|---|---|
| Job completed successfully | Step → `succeeded` |
| Job raised, retries remaining | No action — `on_finish` hasn't fired |
| Job exhausted retries | Step → `failed` |
| Job discarded via `discard_on` | Step → `failed` |

This ensures a step is never prematurely marked `failed` on attempt 1 of 5.

## Design decisions

1. Postgres only -- all state in Postgres, which is what makes atomic enqueue transactions possible
2. One batch per step -- user jobs are enqueued via `perform_later`, so all ActiveJob semantics (instrumentation, callbacks, retries, `discard_on`) work as expected
3. Terminal signal comes from `batch.succeeded?`, not exception rescue
4. `coordination_status` is the sole decision input -- the coordinator reads only this column
5. `:halted` is policy-driven -- set via `halt_triggered` flag, not pattern-derived
6. The coordinator owns all transitions; `StepFinishedJob` is a thin dispatcher
7. Pipeline-first lock ordering serializes completion, enqueue, and cancellation within one coordination transaction
8. DAG validation runs at instantiation, before any database writes
9. `failure_strategy` and `on_failure` are distinct concepts -- strategy vs. callback, no naming collision

## Why these tradeoffs

GoodPipeline is intentionally GoodJob-specific and Postgres-only. This is what enables atomic enqueue transactions — step status transitions and GoodJob record inserts happen in a single database transaction, eliminating an entire class of partial-state bugs that adapter-agnostic gems must work around.

The DAG execution model (vs. strictly sequential steps) adds coordination complexity — row locks, atomic counters, fan-in race prevention — but unlocks parallel execution of independent steps. For workflows where steps have no dependency on each other, this means wall-clock time is bounded by the longest path through the graph, not the sum of all steps.

The four-table data model (pipelines, steps, dependencies, chains) is more tables than a two-table approach, but dedicated dependency and chain tables enable efficient graph queries and keep the step table free of self-referential joins.
