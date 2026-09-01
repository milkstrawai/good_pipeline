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

### vs. Active Job Continuation (Rails 8.1)

Rails 8.1 ships with `ActiveJob::Continuable`, which lets a single job define sequential steps with cursor-based progress tracking. If a deploy kills the process, the job resumes from its last checkpoint instead of restarting from scratch.

This solves a different problem than GoodPipeline. Continuation makes one long-running job resilient to interruption. GoodPipeline orchestrates multiple independent jobs as a DAG with parallel execution, fan-out/fan-in, branching, and pipeline-level failure strategies.

The two are complementary: a GoodPipeline step that processes millions of records could use `Continuable` internally for checkpoint/resume, while GoodPipeline handles the higher-level orchestration around it.

### vs. Geneva Drive

[Geneva Drive](https://github.com/julik/geneva_drive) is a durable workflow framework that executes steps strictly sequentially — one step at a time, like the mechanical gear it's named after. It works with any ActiveJob adapter (Sidekiq, Solid Queue, GoodJob) and supports PostgreSQL, MySQL, and SQLite.

Geneva Drive is a strong choice for linear, long-lived workflows with pause/resume with human-in-the-loop recovery and per-hero workflow uniqueness constraints. Its layered exception policy system is particularly sophisticated.

GoodPipeline takes a different approach: workflows are DAGs, not linear chains. Independent steps run in parallel across workers. Fan-out, fan-in, conditional branching, and pipeline chaining are first-class primitives. The tradeoff is that GoodPipeline requires GoodJob and PostgreSQL specifically, while Geneva Drive is adapter- and database-agnostic.

Choose Geneva Drive when your workflow is inherently sequential and you need pause/resume or adapter flexibility. Choose GoodPipeline when steps can run concurrently, your workflow has branching or fan-in topology, or you want a built-in dashboard with DAG visualization.

## Features

- `run`, `barrier`, and `branch` DSL for defining dependencies, phase boundaries, and conditional paths
- Steps without dependencies run concurrently
- Three failure strategies: `:halt`, `:continue`, `:ignore` (pipeline-level and per-step)
- Pipeline chaining with serial chains, fan-out, fan-in, and parallel start
- `on_complete`, `on_success`, `on_failure` lifecycle callbacks with transactional enqueue-once dispatch
- Mountable Rails engine with execution list, DAG visualization, and definitions catalog
- Automatic cleanup that piggybacks on GoodJob's cleanup cycle
- Postgres-only: no Redis, atomic enqueue transactions

## Requirements

- Ruby >= 3.2
- Rails >= 7.2
- PostgreSQL
- GoodJob >= 4.14 with `preserve_job_records = true`
