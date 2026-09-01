# Defining Pipelines

## Pipeline class structure

Every pipeline is a subclass of `GoodPipeline::Pipeline` that implements `configure`:

```ruby
class VideoProcessingPipeline < GoodPipeline::Pipeline
  description "Downloads, transcodes and publishes a video"
  failure_strategy :halt
  coordination_queue_name "video_coordination"
  callback_queue_name "video_callbacks"

  on_complete :notify
  on_success  :celebrate
  on_failure  :alert

  def configure(video_id:)
    run :download,  DownloadJob,  with: { video_id: video_id }
    run :transcode, TranscodeJob, after: :download
    run :thumbnail, ThumbnailJob, after: :download
    run :publish,   PublishJob,   after: %i[transcode thumbnail]
    run :cleanup,   CleanupJob,   after: :publish
  end

  private

  def notify = Rails.logger.info("Pipeline complete")
  def celebrate = Rails.logger.info("All steps succeeded!")
  def alert = Rails.logger.warn("Pipeline had failures")
end
```

**Class-level methods:**

| Method | Purpose | Default |
|---|---|---|
| `display_name` | Override the pipeline name shown on the dashboard | `nil` (falls back to `underscore.titleize`) |
| `description` | Human-readable label for the dashboard | `nil` |
| `failure_strategy` | Pipeline-level failure handling policy | `:halt` |
| `on_complete` | Callback for any terminal state | `nil` |
| `on_success` | Callback for succeeded | `nil` |
| `on_failure` | Callback for failed or halted | `nil` |
| `coordination_queue_name` | Queue for `StepFinishedJob` and `PipelineReconciliationJob` | `"good_pipeline_coordination"` |
| `callback_queue_name` | Queue for `PipelineCallbackJob` | `"good_pipeline_callbacks"` |

## DSL verbs

There are three DSL verbs: `run` for defining steps, `barrier` for phase boundaries, and `branch` for conditional paths. See [Conditional Branching](/branching) for the `branch` DSL.

## The `run` DSL verb

All DAG topology is expressed through `after:` edges:

```ruby
run :step_key, JobClass,
  with:       { keyword: args },               # keyword args passed to job's perform method
  after:      :other_step,                     # single dependency (symbol or array of symbols)
  on_failure: :ignore,                         # step-level failure strategy override
  enqueue:    { queue: :media, priority: 10 }  # options passed to job.enqueue()
```

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `key` | Symbol | Yes | Unique step identifier within this pipeline |
| `job_class` | Class | Yes | The ActiveJob class to execute |
| `with:` | Hash | No | Keyword arguments forwarded to the job's `perform` method |
| `after:` | Symbol or Array | No | Step key(s) this step depends on |
| `on_failure:` | Symbol | No | Override: `:halt`, `:continue`, or `:ignore` |
| `enqueue:` | Hash | No | Options passed through to `job.enqueue()` (see below) |

### Enqueue options

The `enqueue:` hash supports any option that ActiveJob's `enqueue` method accepts, except `wait_until`:

| Key | Type | Description |
|---|---|---|
| `queue` | String/Symbol | Queue name for this step's job |
| `priority` | Integer | Priority for this step's job |
| `wait` | Numeric | Delay in seconds after dependencies are satisfied |
| `good_job_labels` | Array | GoodJob labels for the job |
| `good_job_notify` | Boolean | Whether GoodJob emits a NOTIFY event |

`wait_until` is not supported because absolute times don't survive JSONB serialization and are semantically wrong in a DAG context — the step may not be enqueued until minutes or hours after the pipeline is created.

## The `barrier` DSL verb

`barrier` separates declarations into phases. Every entry step in the following phase waits for every exit step in the preceding phase:

```ruby
run :fetch_users,  FetchUsersJob
run :fetch_orders, FetchOrdersJob

barrier

run :index_users,  IndexUsersJob
run :index_orders, IndexOrdersJob

barrier

run :publish, PublishJob
```

Within a phase, jobs still use normal `after:` dependencies and run concurrently when possible. Explicit dependencies remain additive and cannot bypass the phase boundary. Multiple top-level barriers are supported, including immediately before or after a branch.

Internally, GoodPipeline persists one structural barrier step and connects `previous phase exits → barrier → next phase entries`. The barrier is resolved synchronously by the coordinator and never creates a GoodJob job or batch. It appears as `Barrier 1`, `Barrier 2`, and so on in the dashboard and counts as a step.

The verb is intentionally narrow:

- It takes no arguments.
- It cannot be first, last, consecutive, or used inside a branch arm.
- A forward `after:` reference may stay within one phase, but cannot cross from an earlier phase to a later phase.
- It is not a sleep or an ensure/finally construct. Existing `:halt`, `:continue`, and `:ignore` dependency semantics apply.

::: warning Deployment ordering
Workers from older GoodPipeline versions do not recognize the barrier sentinel. Deploy the barrier-aware gem version to every web and worker process that can run coordinator code before deploying pipeline definitions that call `barrier`.
:::

## Step keys vs job classes

The **step key** is the graph identity — it's what you reference in `after:`. The **job class** is the implementation — what code runs:

| Concept | Purpose | Example |
|---|---|---|
| Step key | Graph identity — used in `after:` | `:transcode_720p` |
| Job class | Implementation — what code runs | `TranscodeJob` |

The same job class can appear multiple times in one pipeline under different keys:

```ruby
run :resize_small, ResizeImageJob, with: { size: "small" }
run :resize_large, ResizeImageJob, with: { size: "large" }
run :combine,      CombineJob,     after: [:resize_small, :resize_large]
```

## DAG topology via `after:`

All topology flows from `after:`. Steps with no `after:` are **root steps** and start immediately. Steps with `after:` wait for all listed dependencies to be satisfied.

### Fan-out

One step feeds into multiple parallel steps:

```ruby
run :download,  DownloadJob
run :transcode, TranscodeJob, after: :download
run :thumbnail, ThumbnailJob, after: :download
```

```
   :download
      ↓
 ┌────┴────┐
 ↓         ↓
:transcode :thumbnail
```

### Fan-in

Multiple steps converge into one:

```ruby
run :transcode, TranscodeJob, after: :download
run :thumbnail, ThumbnailJob, after: :download
run :publish,   PublishJob,   after: [:transcode, :thumbnail]
```

`:publish` waits for **both** `:transcode` and `:thumbnail` to succeed.

### Complex DAGs

Combine fan-out and fan-in freely:

```ruby
def configure(video_id:)
  run :download,  DownloadJob,  with: { video_id: video_id }
  run :transcode, TranscodeJob, after: :download
  run :thumbnail, ThumbnailJob, after: :download
  run :publish,   PublishJob,   after: [:transcode, :thumbnail]
  run :cleanup,   CleanupJob,   after: :publish
end
```

```
   :download
      ↓
 ┌────┴────┐
 ↓         ↓
:transcode :thumbnail
 └────┬────┘
      ↓
  :publish
      ↓
  :cleanup
```

## Running a pipeline

```ruby
# Fire and forget
VideoProcessingPipeline.run(video_id: 123)

# Capture the result for monitoring or chaining
pipeline = VideoProcessingPipeline.run(video_id: 123)
pipeline.id      # => "uuid-string"
pipeline.status  # => "running"
```

`.run` returns a `GoodPipeline::Chain` object that delegates common methods (`id`, `status`, `params`, `steps`, etc.) to the underlying pipeline record.

## Definition freeze semantics

Once a pipeline instance is created and validated:

1. The graph topology is **immutable** — steps and edges are written to the database and cannot be modified
2. All step definitions are frozen
3. The params hash is frozen

This ensures the pipeline definition is a snapshot — later changes to the pipeline class don't affect running instances.
