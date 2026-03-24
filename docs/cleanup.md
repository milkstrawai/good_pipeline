# Cleanup

GoodPipeline cleans up old terminal pipelines automatically when GoodJob runs its own cleanup cycle. No extra configuration needed.

## Automatic cleanup

GoodPipeline subscribes to GoodJob's `cleanup_preserved_jobs` ActiveSupport notification. When GoodJob cleans its old job records, GoodPipeline deletes terminal pipelines older than the same timestamp.

It uses GoodJob's existing retention period (default 14 days), runs whenever GoodJob's cleanup runs, and only touches terminal pipelines (`succeeded`, `failed`, `halted`, `skipped`). Running and pending pipelines are never deleted.

## What gets cleaned

When a pipeline is cleaned up, the following records are deleted:

1. `good_pipeline_dependencies` — step dependency edges
2. `good_pipeline_steps` — step records
3. `good_pipeline_chains` — pipeline chain links
4. `good_pipeline_pipelines` — pipeline records

Records are deleted in dependency order using `delete_all` (no callbacks) for performance.

## Configuring the retention period

The retention period is controlled by GoodJob's configuration:

```ruby
# config/application.rb
config.good_job.cleanup_preserved_jobs_before_seconds_ago = 30.days.to_i
```

The default is 14 days. GoodPipeline uses the same threshold.

## Manual cleanup

You can trigger cleanup manually at any time:

```ruby
GoodPipeline.cleanup_preserved_pipelines(older_than: 7.days.ago)
```

This deletes all terminal pipelines (and their associated steps, dependencies, and chains) created before the given timestamp.
