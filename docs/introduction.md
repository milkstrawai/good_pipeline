# Introduction

GoodPipeline is a Ruby gem for DAG-based (Directed Acyclic Graph) workflow orchestration in Rails, using [GoodJob](https://github.com/bensheldon/good_job) as the job backend. You define pipelines of jobs that run in parallel or with explicit dependencies, chain pipelines together, and monitor execution. The only infrastructure requirement is Postgres.

## Why GoodPipeline?

### What's missing

The two prominent DAG workflow gems in Ruby are:

- **[Gush](https://github.com/chaps-io/gush)** — graph-based with a clean DSL, but requires **Sidekiq + Redis**
- **[Jongleur](https://gitlab.com/RedFred7/Jongleur)** — DAG-based, but runs jobs as **OS processes**, not ActiveJob workers

Neither integrates with GoodJob. Teams that have chosen GoodJob for its Postgres-only simplicity have no DAG workflow option that stays within that constraint.

### Why GoodJob::Batch isn't enough

GoodJob's Batch feature fires a single `on_finish` callback when all jobs in a batch complete. This is powerful for fan-out/fan-in patterns but insufficient for DAGs because:

- There is no per-job completion hook
- There is no concept of edges (dependencies) between individual jobs
- There is no way to express "enqueue Job C only after Job A and Job B both succeed"

GoodPipeline adds a coordination state machine, DAG validation, and atomic step transitions on top of Batch.

## Features

- `run` and `branch` DSL for defining step dependencies and conditional paths
- Steps without dependencies run concurrently
- Three failure strategies: `:halt`, `:continue`, `:ignore` (pipeline-level and per-step)
- Pipeline chaining with serial chains, fan-out, fan-in, and parallel start
- `on_complete`, `on_success`, `on_failure` lifecycle callbacks with exactly-once dispatch
- Mountable Rails engine with execution list, DAG visualization, and definitions catalog
- Automatic cleanup that piggybacks on GoodJob's cleanup cycle
- Postgres-only: no Redis, atomic enqueue transactions

## Requirements

- Ruby >= 3.2
- Rails >= 7.1
- PostgreSQL
- GoodJob >= 3.10 with `preserve_job_records = true`
