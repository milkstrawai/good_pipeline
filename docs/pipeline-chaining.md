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

Pipeline chaining is a first-class primitive — upstream/downstream relationships are tracked in a dedicated database table and processed by an idempotent, row-locked coordinator, rather than manually creating the next workflow in the last step of the current one.

## How `.then` works internally

`.then` returns a `GoodPipeline::Chain` object which:

1. Creates downstream pipeline records with `status: pending` — params are stored immediately at chain registration time
2. Creates `good_pipeline_chains` rows linking upstream to downstream pipeline IDs
3. If any upstream has already reached a terminal state, immediately triggers chain propagation so the downstream is started or skipped
4. After any upstream pipeline reaches a terminal state, the chain coordinator checks if all upstreams for each downstream have succeeded
5. If all upstreams succeeded, the downstream pipeline starts (root steps are enqueued)
6. If any upstream fails, halts, is canceled, or is skipped, the downstream pipeline is set to `skipped`

The chain coordinator uses a blocking `FOR UPDATE` row lock. A contending propagation waits, then rechecks the downstream pipeline while locked, so a fan-in wake-up cannot be silently dropped. This also makes `.then` safe to call after an upstream has already completed.

Individual chain transitions are atomic and propagation is idempotent, but delivery after an upstream commit is currently an in-process callback rather than a durable outbox. A process death in that narrow window can require explicit reconciliation of a still-pending downstream chain.

## Unsuccessful upstream propagation

If any upstream pipeline in a chain fails, halts, is canceled, or is skipped:

- The downstream pipeline transitions to `skipped`
- Any further downstream pipelines are also recursively `skipped`
- `on_complete` callbacks fire on skipped pipelines, but `on_failure` does **not** — being skipped is not considered a failure

```
A (failed) → B (skipped) → C (skipped) → D (skipped)
```

A `canceling` upstream is still nonterminal, so its downstream pipelines remain pending while already-enqueued work drains. Once the upstream reaches `canceled`, normal chain propagation skips the pending downstream graph.
