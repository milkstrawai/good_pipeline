---
layout: home

hero:
  name: GoodPipeline
  text: DAG-based job pipelines for Rails
  tagline: Postgres-only workflow orchestration built on GoodJob. Define multi-step workflows as directed acyclic graphs with dependency resolution, parallel execution, and failure strategies.
  actions:
    - theme: brand
      text: Get Started
      link: /getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/milkstrawai/good_pipeline

features:
  - title: Postgres only
    details: All state lives in Postgres. No Redis, no external dependencies. Step transitions and job enqueues happen in a single database transaction.
  - title: DAG orchestration
    details: Define pipelines as directed acyclic graphs — not just linear chains. Steps run in parallel when possible, synchronize at explicit barriers, and take different paths based on runtime decisions. Fan-out, fan-in, phase barriers, branching, and chaining are all first-class.
  - title: Web dashboard
    details: A mountable Rails engine with pipeline executions, step details, DAG visualization, and a pipeline definitions catalog. No build step.
---
