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

GoodPipeline will raise `GoodPipeline::ConfigurationError` at boot if this is not set.

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
