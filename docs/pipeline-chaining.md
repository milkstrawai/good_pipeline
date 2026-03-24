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

## How `.then` works internally

`.then` returns a `GoodPipeline::Chain` object which:

1. Creates downstream pipeline records with `status: pending` — params are stored immediately at chain registration time
2. Creates `good_pipeline_chains` rows linking upstream to downstream pipeline IDs
3. If any upstream has already reached a terminal state, immediately triggers chain propagation so the downstream is started or skipped
4. After any upstream pipeline reaches a terminal state, the chain coordinator checks if all upstreams for each downstream have succeeded
5. If all upstreams succeeded, the downstream pipeline starts (root steps are enqueued)
6. If any upstream fails, halts, or is skipped, the downstream pipeline is set to `skipped`

The chain coordinator uses the **same atomic row-locking pattern** (`FOR UPDATE SKIP LOCKED`) as the step-level coordinator to prevent double-start races. This means `.then` is safe to call at any time — even after the upstream has already completed.

## Failure propagation

If any upstream pipeline in a chain fails, halts, or is skipped:

- The downstream pipeline transitions to `skipped`
- Any further downstream pipelines are also recursively `skipped`
- `on_complete` callbacks fire on skipped pipelines, but `on_failure` does **not** — being skipped is not considered a failure

```
A (failed) → B (skipped) → C (skipped) → D (skipped)
```
