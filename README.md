# GoodPipeline

DAG-based job pipeline orchestration for Rails, built on [GoodJob](https://github.com/bensheldon/good_job).

Define multi-step workflows as directed acyclic graphs — not linear chains. Steps run in parallel when they can and wait for dependencies when they must. GoodPipeline handles dependency resolution, parallel execution, failure strategies, conditional branching, pipeline chaining, and lifecycle callbacks. It also ships with a web dashboard.

## Requirements

- Ruby >= 3.2
- Rails >= 7.2
- PostgreSQL
- GoodJob >= 4.14 with `preserve_job_records = true`

## Installation

Add to your Gemfile:

```ruby
gem "good_pipeline"
```

Then install the migrations:

```bash
bin/rails generate good_pipeline:install
bin/rails db:migrate
```

When upgrading an existing application to GoodPipeline 0.5, add the dashboard indexes before serving a large execution history:

```bash
bin/rails generate good_pipeline:upgrade
bin/rails db:migrate
```

The upgrade generator is idempotent: if its dashboard-index migration already exists, a second invocation reports a no-op instead of creating another file.

GoodPipeline requires GoodJob to preserve job records. Add this to your GoodJob configuration:

```ruby
# config/initializers/good_job.rb
GoodJob.preserve_job_records = true
```

GoodPipeline will raise `GoodPipeline::ConfigurationError` at boot if this is not set.

## Usage

### Defining a pipeline

Subclass `GoodPipeline::Pipeline` and implement `configure`. Use `run` to declare steps and `after:` to express dependencies:

```ruby
class VideoProcessingPipeline < GoodPipeline::Pipeline
  description "Downloads, transcodes and publishes a video"
  failure_strategy :halt

  on_complete :notify
  on_success :celebrate
  on_failure :alert

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

This produces the following DAG:

```mermaid
graph TD
  download --> transcode
  download --> thumbnail
  transcode --> publish
  thumbnail --> publish
  publish --> cleanup
```

### Running a pipeline

```ruby
VideoProcessingPipeline.run(video_id: 123)
```

### Step options

```ruby
run :step_key, JobClass,
  with:       { key: "value" },                # keyword args passed to the job
  after:      :other_step,                     # dependency (symbol or array of symbols)
  on_failure: :ignore,                         # step-level failure strategy override
  enqueue:    { queue: :media, priority: 10 }  # options passed to job.enqueue()
```

### Failure strategies

Set at the pipeline level with `failure_strategy`:

| Strategy | Behaviour |
|---|---|
| `:halt` (default) | Stop all pending steps when any step fails |
| `:continue` | Let independent branches continue; skip only blocked downstream steps |
| `:ignore` | Treat failures as successes for dependency resolution |

Per-step overrides via `on_failure:` in `run` apply to that step's outgoing edges only.

### Conditional branching

Use `branch` to take different paths at runtime based on application state:

```ruby
class MediaPipeline < GoodPipeline::Pipeline
  def configure(media_id:)
    run :analyze, AnalyzeJob, with: { media_id: media_id }

    branch :format_check, after: :analyze, by: :detect_format do
      on :hd do
        run :transcode_hd, TranscodeHDJob, with: { media_id: media_id }
        run :upscale, UpscaleJob, with: { media_id: media_id }, after: :transcode_hd
      end

      on :sd do
        run :transcode_sd, TranscodeSDJob, with: { media_id: media_id }
      end
    end

    run :publish, PublishJob, after: :format_check
  end

  private

  def detect_format
    Media.find(params[:media_id]).hd? ? :hd : :sd
  end
end
```

The `by:` method is evaluated at runtime when the branch step is reached. The matching arm runs; other arms are skipped. `after: :format_check` waits for whichever arm was chosen to complete.

Arms can also be empty for an if-without-else pattern:

```ruby
branch :quality_check, after: :analyze, by: :needs_processing do
  on :yes do
    run :process, ProcessJob
  end
  on :no  # skip — pipeline continues to next step
end
```

The dashboard renders branches as diamond decision nodes with labeled edges.

### Pipeline chaining

Chain pipelines together with `.then()`:

```ruby
# Serial chain
VideoProcessingPipeline
  .run(video_id: 123)
  .then(NotificationPipeline, with: { video_id: 123 })

# Fan-out
VideoProcessingPipeline
  .run(video_id: 123)
  .then(
    [NotificationPipeline, with: { video_id: 123 }],
    [AnalyticsPipeline,    with: { video_id: 123 }]
  )

# Parallel start with fan-in
GoodPipeline.run(
  [VideoProcessingPipeline, with: { video_id: 123 }],
  [AudioProcessingPipeline, with: { audio_id: 456 }]
).then(MergeMediaPipeline, with: { video_id: 123, audio_id: 456 })
```

If an upstream pipeline fails, halts, is canceled, or is skipped, downstream pipelines are automatically skipped.

### Monitoring

```ruby
pipeline = VideoProcessingPipeline.run(video_id: 123)

pipeline.status     # => "running"
pipeline.terminal?  # => false
pipeline.steps      # => all step records
pipeline.params     # => { "video_id" => 123 }

# Query across pipelines
GoodPipeline::PipelineRecord.where(status: "failed")
GoodPipeline::PipelineRecord.where(type: "VideoProcessingPipeline")
```

### Lifecycle callbacks

```ruby
class MyPipeline < GoodPipeline::Pipeline
  on_complete :always_runs    # any terminal state
  on_success  :only_success   # pipeline succeeded
  on_failure  :only_failure   # pipeline failed or halted
end
```

Callbacks are dispatched asynchronously via a separate GoodJob job. They never block the coordinator or affect pipeline state.

## Dashboard

GoodPipeline includes a mountable web dashboard for inspecting pipeline executions:

```ruby
# config/routes.rb
# Protect this mount with your application's administrator authentication.
mount GoodPipeline::Engine => "/good_pipeline"
```

The engine does not provide authentication. Treat the dashboard as an admin-only interface and see [Securing the dashboard](docs/dashboard.md#securing-the-dashboard) for mount examples.

Pipeline mutation controls are read-only by default. After protecting the mount, enable cancellation and re-running explicitly:

```ruby
# config/initializers/good_pipeline.rb
GoodPipeline.dashboard_mutations_enabled = true
```

This setting only enables dashboard actions; it does not authenticate or authorize visitors. The theme preference remains available while pipeline mutations are disabled.

The dashboard provides:

- Pipeline executions with composable type, status, time, and text filters, offset pagination, live status counts, and expandable step timelines
- Operational KPIs for the selected pipeline type, including current activity, fixed-window failure and duration statistics, and a 14-day sparkline
- Pipeline details with GoodJob links, step errors, chain links, a stage timeline, and an interactive DAG
- A definition catalog with declared dependencies and structural DAG or stage views

Dark is the default theme in 0.5. The topbar toggle persists a light or dark preference in a permanent same-site cookie. Dashboard styles and JavaScript ship with the gem; Mermaid and web fonts are loaded from their CDNs, so there is no application-side asset build step.

Large executions remain readable: rows with more than 12 steps use an aggregate status bar, and DAGs with more than 60 steps initially show a stage view. A full graph remains available up to Mermaid's 1,000-edge safety limit. Above that limit, the stage view stays available and full rendering is disabled explicitly.

### Canceling a pipeline

Dashboard cancellation is graceful: it stops future DAG scheduling, not work already handed to GoodJob. A pending pipeline becomes `canceled` immediately. A running pipeline becomes `canceling`, and its `pending` steps become `canceled`; jobs that are already enqueued, scheduled, or retrying run normally and retain their actual `succeeded`, `failed`, or `halted` outcomes. No GoodJob records are changed and no worker is force-terminated.

After the last enqueued job finishes, the pipeline becomes `canceled`. Until then, `canceling` is an active, nonterminal state. A pipeline can remain `canceling` indefinitely if an enqueued job never reaches a terminal outcome.

### Re-running a pipeline

The dashboard can re-run a terminal pipeline (`succeeded`, `failed`, `halted`, `skipped`, or `canceled`). A re-run is a new standalone execution, not a retry or resumption of the historical one. It starts from the root steps using the source execution's stored JSON parameters and the pipeline's current Ruby definition, so code changes made since the source ran are applied.

The source execution, its steps, jobs, callbacks, and status remain unchanged. Pipeline-chain relationships are not copied: upstream pipelines are not attached to the new execution, and downstream pipelines are not re-run. Normal branching and failure rules still apply, and jobs, callbacks, and external side effects may run again. Each confirmed submission intentionally creates another execution.

If the pipeline class has been removed, the stored parameters are no longer compatible, or the current definition is invalid, the dashboard creates nothing and reports that the pipeline could not be re-run. Re-run controls remain disabled while an execution is `pending`, `running`, or `canceling`.

### Pipeline Executions

![Pipeline Executions](docs/screenshots/index.png)

### Pipeline Details

![Pipeline Details](docs/screenshots/show.png)

### Pipeline Definitions

![Pipeline Definitions](docs/screenshots/definitions.png)

## Cleanup

GoodPipeline automatically cleans up old terminal pipelines when GoodJob runs its own cleanup cycle. No configuration needed, it uses GoodJob's retention period (default 14 days).

Pending, running, and canceling pipelines are intentionally retained; canceled pipelines are terminal and follow the normal retention window. GoodJob may still remove old job rows belonging to a long-running or canceling pipeline, so timing for those steps appears as `—` in the dashboard after the retention window; the pipeline and step coordination records remain available.

To configure the retention period, set GoodJob's option:

```ruby
# config/application.rb
config.good_job.cleanup_preserved_jobs_before_seconds_ago = 30.days.to_i
```

## Development

```bash
bin/setup
mise docker:start  # PostgreSQL
rake test
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/milkstrawai/good_pipeline.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
