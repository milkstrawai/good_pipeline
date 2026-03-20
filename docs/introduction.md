# Introduction

GoodPipeline is a Ruby gem that brings DAG-based (Directed Acyclic Graph) workflow orchestration to Rails applications using [GoodJob](https://github.com/bensheldon/good_job) as the job backend. It allows you to define pipelines of jobs that run in parallel or with explicit dependencies, chain multiple pipelines together, and monitor execution — all without any infrastructure beyond Postgres.

## Why GoodPipeline?

### The gap in the ecosystem

The two prominent DAG workflow gems in Ruby are:

- **[Gush](https://github.com/chaps-io/gush)** — graph-based with a clean DSL, but requires **Sidekiq + Redis**
- **[Jongleur](https://gitlab.com/RedFred7/Jongleur)** — DAG-based, but runs jobs as **OS processes**, not ActiveJob workers

Neither integrates with GoodJob. Teams that have chosen GoodJob for its Postgres-only simplicity have no DAG workflow option that stays within that constraint.

### Why GoodJob::Batch isn't enough

GoodJob's Batch feature fires a single `on_finish` callback when all jobs in a batch complete. This is powerful for fan-out/fan-in patterns but insufficient for DAGs because:

- There is no per-job completion hook
- There is no concept of edges (dependencies) between individual jobs
- There is no way to express "enqueue Job C only after Job A and Job B both succeed"

GoodPipeline solves this by building a formal coordination state machine, DAG validation, and atomic coordination layer on top of Batch.

## Key features

- **DAG topology via `run` DSL** — define steps and their dependencies with a single verb
- **Parallel execution** — steps without dependencies run concurrently
- **Three failure strategies** — `:halt`, `:continue`, and `:ignore` at pipeline and step level
- **Pipeline chaining** — serial chains, fan-out, fan-in, and parallel start
- **Lifecycle callbacks** — `on_complete`, `on_success`, `on_failure` with exactly-once dispatch
- **Built-in dashboard** — mountable Rails engine with execution list, DAG visualization, and definitions catalog
- **Automatic cleanup** — piggybacks on GoodJob's cleanup cycle
- **Postgres-only** — all state in Postgres, no Redis, atomic enqueue transactions

## Requirements

- Ruby >= 3.2
- Rails >= 7.1
- PostgreSQL
- GoodJob >= 3.10 with `preserve_job_records = true`
