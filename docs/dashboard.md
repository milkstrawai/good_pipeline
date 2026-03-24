# Web Dashboard

GoodPipeline ships with a mountable Rails engine for inspecting pipeline executions. No build step -- it uses Pico CSS and Mermaid.js from CDN.

## Mounting the engine

```ruby
# config/routes.rb
mount GoodPipeline::Engine => "/good_pipeline"
```

The dashboard is then available at `/good_pipeline`.

## Pages

### Pipeline Executions

The index page lists all pipeline executions with:

- Status filter tabs with per-status counts
- Pipeline type dropdown filter
- Execution ID, pipeline name, status badge, start time, and duration
- Keyset pagination (25 per page)

![Pipeline Executions](/screenshots/index.png)

### Pipeline Details

The show page displays a single pipeline execution with:

- Pipeline metadata: status, failure strategy, params, created time, duration
- Mermaid DAG visualization with color-coded step statuses, diamond nodes for branches, and labeled arm edges
- Steps table with coordination status, job class, duration, error info, and links to the GoodJob dashboard
- Upstream and downstream chain links (if the pipeline is part of a chain)

![Pipeline Details](/screenshots/show.png)

### Pipeline Definitions

The definitions page catalogs all pipeline types found in the database:

- Sidebar listing all pipeline types with step counts
- Selected pipeline shows its Mermaid DAG structure, failure strategy, and a link to filter executions by that type

![Pipeline Definitions](/screenshots/definitions.png)

## GoodJob integration

The dashboard links to GoodJob's dashboard for individual step jobs when a `good_job_id` is present on a step. It automatically discovers GoodJob's mount path from your application's routes.

## Securing the dashboard

GoodPipeline's engine is a standard Rails engine mount. Secure it the same way you would any admin interface:

```ruby
# config/routes.rb

# With Devise
authenticate :user, ->(user) { user.admin? } do
  mount GoodPipeline::Engine => "/good_pipeline"
end

# With Rails routing constraints
mount GoodPipeline::Engine => "/good_pipeline",
  constraints: AdminConstraint.new
```
