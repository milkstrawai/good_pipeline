# Installation & Setup

## Install the gem

Add GoodPipeline to your Gemfile:

```ruby
gem "good_pipeline"
```

Then install:

```bash
bundle install
```

## Run the install generator

The install generator creates the database migration:

```bash
bin/rails generate good_pipeline:install
bin/rails db:migrate
```

This creates four tables: `good_pipeline_pipelines`, `good_pipeline_steps`, `good_pipeline_dependencies`, and `good_pipeline_chains`.

## Configure GoodJob

GoodPipeline requires GoodJob to preserve job records so it can read terminal failure metadata:

```ruby
# config/initializers/good_job.rb
GoodJob.preserve_job_records = true
```

It also requires an execution mode in which jobs are handed to a worker through the database rather than run during enqueue. `:external` qualifies. An async variant qualifies only when it is effectively in-process and `poll_interval > 0`; LISTEN/NOTIFY may reduce latency, but it is not a substitute for polling.

One of GoodJob's own defaults does not qualify: the test environment defaults to `:inline`, so test configs need one line:

```ruby
# config/environments/test.rb — GoodJob defaults the test environment to :inline
config.good_job.execution_mode = :external
```

In tests, drain the queue with `GoodJob.perform_inline` after starting a pipeline.

A development async mode can default to `poll_interval = -1`, which disables polling and is unsafe for GoodPipeline. During a transactional enqueue, GoodJob can create a local worker before commit; that worker cannot see the new row and GoodJob suppresses `NOTIFY` because it was created. Positive polling is the recovery path even when LISTEN/NOTIFY is enabled:

```ruby
config.good_job.poll_interval = 10
```

GoodPipeline raises `GoodPipeline::ConfigurationError` at boot if any of these is unmet. It also rejects effective enqueue deferral, not merely a raw GoodJob setting: Rails 7.2, 8.0, and 8.1 interpret `enqueue_after_transaction_commit` differently, and GoodPipeline mirrors the installed Active Job behavior.

## Configure queue names (optional)

GoodPipeline routes its internal jobs to dedicated queues by default. You can override them globally:

```ruby
# config/initializers/good_pipeline.rb
GoodPipeline.coordination_queue_name = "pipeline_coordination"  # StepFinishedJob, PipelineReconciliationJob, ChainPropagationJob
GoodPipeline.callback_queue_name = "pipeline_callbacks"         # PipelineCallbackJob
```

Defaults are `"good_pipeline_coordination"` and `"good_pipeline_callbacks"`. Per-pipeline overrides are also available via the class DSL — see [Defining Pipelines](/defining-pipelines).

## Mount the dashboard (optional)

```ruby
# config/routes.rb
mount GoodPipeline::Engine => "/good_pipeline"
```

See the [Web Dashboard](/dashboard) page for details.

## Your first pipeline

Define a pipeline by subclassing `GoodPipeline::Pipeline` and implementing `configure`:

```ruby
class DataIngestionPipeline < GoodPipeline::Pipeline
  description "Fetches, transforms, and loads data"

  def configure(source_id:)
    run :fetch,     FetchJob,     with: { source_id: source_id }
    run :transform, TransformJob, with: { source_id: source_id }, after: :fetch
    run :load,      LoadJob,      with: { source_id: source_id }, after: :transform
  end
end
```

Run it:

```ruby
DataIngestionPipeline.run(source_id: 42)
```

This enqueues `:fetch` immediately. When it succeeds, `:transform` is enqueued. When that succeeds, `:load` is enqueued. If any step fails, the pipeline halts by default.

## Next steps

- [Defining Pipelines](/defining-pipelines) — full DSL reference and DAG patterns
- [Conditional Branching](/branching) — take different paths at runtime
- [Failure Strategies](/failure-strategies) — control what happens when steps fail
- [Pipeline Chaining](/pipeline-chaining) — wire pipelines together
- [Monitoring](/monitoring) — inspect pipeline and step state
