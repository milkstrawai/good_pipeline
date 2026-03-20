---
layout: home

hero:
  name: GoodPipeline
  text: DAG-based job pipelines for Rails
  tagline: Postgres-only workflow orchestration built on GoodJob. Define multi-step workflows as directed acyclic graphs with dependency resolution, parallel execution, failure strategies, and a built-in dashboard.
  actions:
    - theme: brand
      text: Get Started
      link: /getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/milkstrawai/good_pipeline

features:
  - title: Postgres Only
    details: All state lives in Postgres — no Redis, no external dependencies. Step transitions and job enqueues are atomically coupled in a single database transaction.
  - title: DAG Orchestration
    details: Define pipelines as directed acyclic graphs with the run DSL. Steps run in parallel when possible and wait for dependencies automatically. Fan-out, fan-in, and chaining are all built in.
  - title: Built-in Dashboard
    details: A mountable Rails engine with pipeline executions, step details with DAG visualization, and a pipeline definitions catalog. No build step — uses CDN assets.
---
