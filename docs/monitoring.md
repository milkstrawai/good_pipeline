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
| `succeeded` | All steps terminal, none failed |
| `failed` | One or more steps failed; `:continue` or `:ignore` strategy was used |
| `halted` | `:halt` strategy was applied — `halt_triggered` is `true` |
| `skipped` | Skipped because an upstream pipeline in a chain failed |

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
