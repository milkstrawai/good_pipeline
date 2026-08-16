# Cleanup

GoodPipeline cleans up old terminal pipelines automatically when GoodJob runs its own cleanup cycle. No extra configuration needed.

## Automatic cleanup

GoodPipeline subscribes to GoodJob's `cleanup_preserved_jobs` ActiveSupport notification. When GoodJob cleans its old job records, GoodPipeline deletes terminal pipelines older than the same timestamp.

It uses GoodJob's existing retention period (default 14 days), runs whenever GoodJob's cleanup runs, and only touches terminal pipelines (`succeeded`, `failed`, `halted`, `skipped`). Running and pending pipelines are never deleted.

A terminal upstream is also retained while any linked downstream is still `pending`. Its status and chain edge are authoritative prerequisites for the durable propagation job; deleting either could strand the downstream or make fan-in appear satisfied with too few upstreams. Once propagation starts or skips the downstream, normal age-based cleanup can remove the old upstream on a later sweep.

## What gets cleaned

When a pipeline is cleaned up, the following records are deleted:

1. `good_pipeline_dependencies` — step dependency edges
2. `good_pipeline_steps` — step records
3. `good_pipeline_chains` — pipeline chain links
4. `good_pipeline_pipelines` — pipeline records

Records are deleted in dependency order using `delete_all` (no callbacks) for performance.

Eligible pipeline rows are locked in primary-key order with `FOR UPDATE SKIP LOCKED`, then rechecked and deleted in one transaction. A row held by settlement, chain registration, cancellation, or another cleanup worker is deferred to a later sweep rather than blocking cleanup or racing a state transition.

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

This deletes all terminal pipelines (and their associated steps, dependencies, and chains) last updated before the given timestamp.

The pending-chain retention rule still applies to manual cleanup. Deployments upgrading from the former in-memory chain handoff should first use the idempotent recovery procedure in [Pipeline Chaining](/pipeline-chaining#recovering-chains-stranded-before-050-hardening); cleanup deliberately retains the records that procedure needs.
