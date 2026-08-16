# Monitoring

GoodPipeline records are ActiveRecord models. Query and inspect them with normal Rails patterns.

## Pipeline instance methods

```ruby
pipeline = VideoProcessingPipeline.run(video_id: 123)

pipeline.id                   # => "uuid-string"
pipeline.status               # => "running"
pipeline.type                 # => "VideoProcessingPipeline"
pipeline.params               # => { "video_id" => 123 }
pipeline.halt_triggered?      # => false
pipeline.terminal?            # => false
pipeline.on_failure_strategy  # => "halt"
pipeline.created_at
pipeline.updated_at
```

## Step instance methods

```ruby
step = pipeline.steps.find_by(key: "transcode")

step.key                  # => "transcode"
step.job_class            # => "TranscodeJob"
step.coordination_status  # => "succeeded"
step.params               # => { "video_id" => 123 }
step.enqueue_options      # => { "queue" => "high", "priority" => 10 }
step.good_job_id          # => "uuid" of the GoodJob record
step.attempts             # => 3
step.error_class          # => "TransientError" (on failure)
step.error_message        # => "Connection timed out" (on failure)
step.duration             # => 12.34 (Float seconds, from GoodJob record)
```

## Pipeline statuses

| Status | Meaning |
|---|---|
| `pending` | Created but root steps not yet enqueued — waiting in a chain |
| `running` | At least one step is enqueued or executing |
| `succeeded` | All steps terminal, none failed, not cancelled |
| `failed` | One or more steps failed; `:continue` or `:ignore` strategy was used |
| `halted` | `:halt` strategy was applied (`halt_triggered` is `true`), **or** an operator cancelled the execution (`canceled_at` is set) |
| `skipped` | Skipped because an upstream pipeline in a chain failed |

A cancelled execution reports `halted` so existing filters, badges and KPI queries keep working unchanged. `canceled_at` is what distinguishes an operator cancel from a failure-driven halt — a cancel sets it and leaves `halt_triggered` false. The dashboard renders the pair as `halted · canceled`.

## Step statuses

The `coordination_status` column is the authoritative step state:

| Status | Meaning |
|---|---|
| `pending` | Waiting for upstream dependencies to be satisfied |
| `enqueued` | Dependencies satisfied; job enqueued |
| `succeeded` | Job completed successfully — terminal |
| `failed` | Job exhausted retries or was discarded — terminal |
| `skipped` | Skipped due to upstream failure propagation — terminal |
| `skipped_by_branch` | Branch decision selected a different arm — terminal, counts as satisfied for downstream |

## Querying with ActiveRecord

```ruby
# Find all failed pipelines in the last 24 hours
GoodPipeline::PipelineRecord.where(status: "failed")
  .where("created_at > ?", 24.hours.ago)

# Find all pipelines of a specific type
GoodPipeline::PipelineRecord.where(type: "VideoProcessingPipeline")

# Find pipelines where a specific job class failed
GoodPipeline::PipelineRecord
  .joins(:steps)
  .where(good_pipeline_steps: {
    job_class: "TranscodeJob",
    coordination_status: "failed"
  })

# Running pipelines
GoodPipeline::PipelineRecord.where(status: "running")
```

## Step associations

Steps expose their dependency graph through associations:

```ruby
step = pipeline.steps.find_by(key: "publish")

step.upstream_steps    # => steps that must complete before this one
step.downstream_steps  # => steps waiting on this one
```

## Step duration

The `duration` method calculates how long a step took to execute by reading timing data from the associated GoodJob record:

```ruby
step.duration  # => 12.34 (seconds as Float), or nil if not available
```

Duration is `nil` if the step hasn't run yet or if the GoodJob record is unavailable.

## Coordination health

GoodPipeline internal work is stored as GoodJob rows. Monitor failed or unusually old jobs for these classes alongside user jobs:

- `GoodPipeline::StepFinishedJob`
- `GoodPipeline::PipelineReconciliationJob`
- `GoodPipeline::ChainPropagationJob`
- `GoodPipeline::PipelineCallbackJob`

Chain propagation is one at-least-once job per edge. Duplicate deliveries are harmless because the downstream transition is guarded by a row lock and `pending` status. A failed edge job can be retried independently without blocking another downstream edge.

A pending chained execution whose upstreams are all terminal is a useful alert condition. For executions stranded by the pre-hardening in-memory handoff, reserve fresh propagation jobs using the recovery procedure in [Pipeline Chaining](/pipeline-chaining#recovering-chains-stranded-before-050-hardening). Cleanup preserves the terminal upstreams and edges needed for that recovery while the downstream remains pending.

## Execution configuration health

In any process where GoodJob executes jobs in process, verify `GoodJob.configuration.poll_interval.to_i > 0`. LISTEN/NOTIFY is useful for latency but is not a substitute: a transaction-local worker wakeup can occur before commit and suppress the corresponding notification. GoodPipeline rejects this configuration at boot and at enqueue boundaries.

Also watch boot and enqueue errors for effective Active Job deferral. The relevant value is the job class's behavior under its Rails version (including per-job overrides), not merely GoodJob's raw `enqueue_after_transaction_commit` setting. See [Architecture](/architecture#enqueue-transaction-contract) for the Rails 7.2, 8.0, and 8.1 rules.
