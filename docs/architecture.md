# Architecture

This page describes GoodPipeline's internal architecture for contributors and advanced users who want to understand how the system works.

## Layer diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        DSL Layer                            │
│    Pipeline.configure defines the DAG topology              │
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
│    One GoodJob::Batch per step                              │
│    User jobs enqueued via perform_later — fully untouched   │
│    Batch on_finish is the sole terminal signal              │
│    Enqueue is transactionally coupled to row transition     │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  Coordination Layer                          │
│    Coordinator owns ALL coordination_status transitions     │
│    Atomic row-locked transitions (FOR UPDATE SKIP LOCKED)   │
│    Explicit transaction boundaries per atomic unit          │
│    recompute_pipeline_status is the sole derivation path    │
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
| `status` | string | `pending`, `running`, `succeeded`, `failed`, `halted`, `skipped` |
| `halt_triggered` | boolean | Set to `true` when `:halt` strategy is applied |
| `good_job_batch_id` | uuid | Pipeline-level GoodJob::Batch for grouping |
| `on_failure_strategy` | string | `halt`, `continue`, or `ignore` |
| `callbacks_dispatched_at` | timestamp | Exactly-once callback dispatch guard |
| `created_at` | timestamp | |
| `updated_at` | timestamp | |

### `good_pipeline_steps`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | Primary key |
| `pipeline_id` | uuid | Foreign key |
| `key` | string | Step key — graph identity |
| `job_class` | string | ActiveJob class name |
| `params` | jsonb | Arguments passed to `with:` |
| `coordination_status` | string | `pending`, `enqueued`, `succeeded`, `failed`, `skipped` |
| `on_failure_strategy` | string | Step-level override (nullable) |
| `queue` | string | Optional queue override |
| `priority` | integer | Optional priority override |
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

## One batch per step

Each step has its own `GoodJob::Batch`. The user's job is enqueued via `perform_later` into that batch, preserving all ActiveJob semantics (instrumentation, callbacks, serialization, queue routing, retries, `discard_on`).

When the batch's `on_finish` fires, `StepFinishedJob` receives the signal and delegates to the coordinator. `StepFinishedJob` is a thin dispatcher — it does not own any state transitions.

## The coordinator

The `Coordinator` class is the sole owner of all `coordination_status` transitions. Its `complete_step` method uses explicit transaction boundaries around three atomic units:

1. **Terminal step transition** — marks the step `succeeded` or `failed` with metadata
2. **Halt propagation** — sets `halt_triggered` and skips all pending steps (if `:halt` strategy)
3. **Downstream unblocking** — checks and enqueues each downstream step independently via `try_enqueue_step`, which acquires a per-step row lock

These three units are intentionally **not** wrapped in a single outer transaction to avoid holding locks across multiple downstream step enqueues under high-parallelism pipelines.

After the three units complete, `complete_step` calls `recompute_pipeline_status` to derive the pipeline's terminal state from the current database state.

## Terminal state derivation

Pipeline terminal status is **never inferred from a single event**. It is always derived by `recompute_pipeline_status`, which reads all step `coordination_status` values and the `halt_triggered` flag:

| Condition | Derived status |
|---|---|
| Any step is `pending` or `enqueued` | Not terminal — still running |
| All steps terminal, none `failed` | `succeeded` |
| All steps terminal, at least one `failed`, `halt_triggered` is `true` | `halted` |
| All steps terminal, at least one `failed`, `halt_triggered` is `false` | `failed` |

This function is safe to call from multiple code paths (coordinator, batch reconciliation) because it is idempotent on terminal pipelines.

## Enqueue transaction contract

The transition of a step from `pending` to `enqueued` and the insertion of the corresponding GoodJob record happen inside a **single database transaction**. This is possible because GoodJob stores jobs in Postgres — the same database as GoodPipeline's tables.

If the transaction rolls back, both the step status revert and the GoodJob record insertion are cancelled atomically. No stuck-enqueued steps, no ghost jobs.

## Concurrency safety

### The double-enqueue problem

If two upstream steps of a shared downstream complete simultaneously, both coordinator invocations may try to enqueue the downstream step. GoodPipeline prevents this with:

1. **`FOR UPDATE SKIP LOCKED`** — one coordinator acquires the row lock; the other skips silently
2. **`good_job_id` null guard** — a non-null `good_job_id` is conclusive proof the step was already enqueued (only valid inside a row lock)
3. **Status guard** — the coordinator checks `coordination_status == "pending"` inside the lock

### Callback exactly-once

`dispatch_callbacks_once` uses a `FOR UPDATE` locked transaction with the `callbacks_dispatched_at` timestamp as a guard. Even if `recompute_pipeline_status` is called concurrently from multiple code paths, the callback bundle fires exactly once.

## Retry model

GoodPipeline never inspects exceptions during retry attempts. It only responds to the **terminal signal** from the step batch's `on_finish` callback:

| GoodJob outcome | GoodPipeline response |
|---|---|
| Job completed successfully | Step → `succeeded` |
| Job raised, retries remaining | No action — `on_finish` hasn't fired |
| Job exhausted retries | Step → `failed` |
| Job discarded via `discard_on` | Step → `failed` |

This ensures a step is never prematurely marked `failed` on attempt 1 of 5.

## Key design decisions

1. **Postgres only** — all state in Postgres, enabling atomic enqueue transactions
2. **One batch per step** — user jobs enqueued via `perform_later`, preserving all ActiveJob semantics
3. **Terminal signal via `batch.succeeded?`** — not exception rescue
4. **`coordination_status` is the sole decision input** — the coordinator reads only this column when making decisions
5. **`:halted` is policy-driven** — set imperatively via `halt_triggered` flag, not pattern-derived
6. **Coordinator owns all transitions** — `StepFinishedJob` is a thin dispatcher
7. **Explicit transaction boundaries** — separate atomic units to minimize lock contention
8. **DAG validation at instantiation** — before any database writes
9. **`run` is the only DSL verb** — all topology from `after:`
10. **`failure_strategy` and `on_failure` are distinct** — strategy vs. callback, no naming collision
