# Pipeline Chaining

Pipelines can be wired together into pipeline-level DAGs. A downstream pipeline starts only after all its upstream pipelines succeed.

## Serial chain

```ruby
VideoProcessingPipeline
  .run(video_id: 123)
  .then(NotificationPipeline, with: { video_id: 123 })
```

`NotificationPipeline` starts only after `VideoProcessingPipeline` succeeds.

## Multi-step serial chain

```ruby
VideoProcessingPipeline
  .run(video_id: 123)
  .then(QualityCheckPipeline, with: { video_id: 123 })
  .then(NotificationPipeline, with: { video_id: 123 })
```

Each pipeline waits for the previous one to succeed.

## Fan-out

Multiple downstream pipelines start in parallel when the upstream succeeds:

```ruby
VideoProcessingPipeline
  .run(video_id: 123)
  .then(
    [NotificationPipeline, with: { video_id: 123 }],
    [AnalyticsPipeline,    with: { video_id: 123 }]
  )
```

Both `NotificationPipeline` and `AnalyticsPipeline` start simultaneously.

## Fan-out then fan-in

```ruby
VideoProcessingPipeline
  .run(video_id: 123)
  .then(QualityCheckPipeline, with: { video_id: 123 })
  .then(
    [NotificationPipeline, with: { video_id: 123 }],
    [AnalyticsPipeline,    with: { video_id: 123 }]
  )
  .then(ArchivePipeline, with: { video_id: 123 })
```

```
VideoProcessingPipeline
          ↓
  QualityCheckPipeline
          ↓
     ┌────┴────┐
     ↓         ↓
Notification Analytics
     └────┬────┘
          ↓
   ArchivePipeline
```

`ArchivePipeline` waits for **both** `NotificationPipeline` and `AnalyticsPipeline` to succeed.

## Parallel start

Run multiple pipelines in parallel from the start using `GoodPipeline.run`:

```ruby
GoodPipeline.run(
  [VideoProcessingPipeline, with: { video_id: 123 }],
  [AudioProcessingPipeline, with: { audio_id: 456 }]
).then(MergeMediaPipeline, with: { video_id: 123, audio_id: 456 })
```

Both pipelines start immediately. `MergeMediaPipeline` waits for both to succeed.

Pipeline chaining is a first-class primitive — upstream/downstream relationships are tracked in a dedicated database table with atomic state propagation, rather than manually creating the next workflow in the last step of the current one.

## How `.then` works internally

`.then` returns a `GoodPipeline::Chain` object which:

1. Builds every requested downstream graph, then creates its `pending` pipeline, steps, and dependencies inside one transaction
2. Locks all upstream pipeline rows in primary-key order, then creates every incoming edge while those locks are held
3. Before that transaction commits, inserts one durable `ChainPropagationJob` for each new edge whose upstream is already terminal
4. When an upstream later settles, commits its terminal status and one propagation job per outgoing edge in the same database transaction
5. Each propagation job reloads its edge and all current statuses; if every upstream succeeded it starts the downstream, and if any failed, halted, or was skipped it skips the downstream

Propagation is durable and at least once. The terminal transition and GoodJob row share a transaction: rollback removes both; commit makes both visible. Jobs carry immutable chain-record IDs and reload state when they run. Duplicate or concurrent deliveries lock the downstream with a **blocking `FOR UPDATE`** and require it still to be `pending`, so exactly one delivery can start or skip it and enqueue its roots.

Registration and settlement use the same upstream-row lock as a handshake. If registration locks first, settlement later sees the committed edge. If settlement locks first, registration waits, then sees the terminal status and creates a propagation job itself. Multiple upstream rows are always locked by primary key, preventing fan-in lock inversion. A job is scoped to one edge, so a transiently broken downstream does not block unrelated downstreams of the same upstream.

## Failure propagation

If any upstream pipeline in a chain fails, halts, or is skipped:

- The downstream pipeline transitions to `skipped`
- Each further downstream pipeline is skipped by its own durable propagation job
- `on_complete` callbacks fire on skipped pipelines, but `on_failure` does **not** — being skipped is not considered a failure

```
A (failed) → B (skipped) → C (skipped) → D (skipped)
```

## Recovering chains stranded before 0.5.0 hardening

Executions already stranded by the former in-memory handoff have no historical propagation job. After deploying this fix, reserve fresh jobs idempotently from a Rails runner; duplicate jobs are safe:

```ruby
GoodPipeline::PipelineRecord
  .where(status: GoodPipeline::PipelineRecord::TERMINAL_STATUSES)
  .find_each do |pipeline|
    GoodPipeline::PipelineRecord.transaction do
      locked = GoodPipeline::PipelineRecord.lock("FOR UPDATE").find(pipeline.id)
      GoodPipeline::ChainCoordinator.reserve_terminal_state!(locked)
    end
  end
```

Cleanup retains a terminal upstream while any linked downstream is still `pending`, so the status and edge needed by this recovery are not removed.
