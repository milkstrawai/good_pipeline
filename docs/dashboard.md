# Web Dashboard

GoodPipeline ships a mountable Rails engine for inspecting executions and pipeline definitions. Its versioned CSS and JavaScript require no host application build step. Mermaid and web fonts are loaded from their CDNs.

## Mounting the engine

```ruby
# config/routes.rb
mount GoodPipeline::Engine => "/good_pipeline"
```

The dashboard is then available at `/good_pipeline`. Links, partial navigation, and the theme endpoint all honor a non-root mount path.

## Theme

The dashboard defaults to dark in GoodPipeline 0.5. Use the topbar control to switch between dark and light; the choice is stored in a permanent, same-site cookie. Dashboard theme state uses `data-gp-theme`, so it does not alter theme attributes used by the host application.

## Pipeline executions

The index page combines:

- A pipeline-type sidebar with run counts, failure strategy, branch, and large-pipeline indicators
- Status, time-window, and ID-prefix/type search filters that compose without dropping one another
- Status counts computed before applying the selected status, so every segment shows the number of rows it would select
- Offset pagination with 25 executions per page
- Expandable rows with step detail, identity and parameters, stage timelines, and copyable Ruby and SQL requery snippets

![Pipeline Executions](/screenshots/index.png)

### KPI scope

The filtered-row KPI matches the pager and therefore respects type, status, time, and search filters. The remaining KPIs are operational summaries scoped only by pipeline type: running now has no time cutoff, while throughput, failures, duration percentiles, and the sparkline use their displayed fixed windows. KPI results are cached together for 30 seconds.

## Pipeline details

The detail page shows identity, parameters, failure strategy, chain links, requery snippets, a step table, an interactive DAG, and a stage timeline. Step keys continue to link to GoodJob when the corresponding job record exists, and failure class/message text remains visible for triage.

![Pipeline Details](/screenshots/show.png)

## Pipeline definitions

The definitions catalog shows each type's strategy, declared steps and dependencies, edge count, execution count, and structural graph.

![Pipeline Definitions](/screenshots/definitions.png)

## Scale behavior

- Up to 12 steps, execution rows show one status marker per step; branch steps use diamond markers.
- Above 12 steps, rows use a stacked status bar and expanded step lists sort failures and active work first.
- Above 60 steps, execution and definition DAGs open in an aggregated stage view. A full graph can still be requested.
- Above 1,000 dependency edges, full Mermaid rendering is disabled with an explanation, independently of the step-count threshold. The stage view stays available.

Mermaid runs in strict security mode. Graph labels are transported as escaped data, and render failures produce a visible error rather than an empty panel.

## GoodJob integration and retention

The dashboard discovers GoodJob's mounted engine path and links to individual jobs. Step durations are loaded in one batch from `good_jobs`; no timing columns are duplicated in GoodPipeline.

GoodPipeline cleanup follows GoodJob's configured preservation window and only deletes terminal pipelines. Pending and running pipelines are retained. If one of those pipelines outlives the GoodJob window, its early job rows may already be gone; affected steps correctly show `—` and no timeline bar.

## Upgrading to 0.5

Existing applications should generate and apply the dashboard indexes:

```bash
bin/rails generate good_pipeline:upgrade
bin/rails db:migrate
```

The generator creates at most one `add_good_pipeline_dashboard_indexes` migration. Indexes are built concurrently and use `if_not_exists`, so the migration is safe to re-run against a database where they already exist.

An interrupted concurrent build can leave an invalid index that PostgreSQL's `if_not_exists` will skip. Check for that state before retrying:

```sql
SELECT c.relname
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
WHERE NOT i.indisvalid
  AND c.relname LIKE 'index_gp_pipelines%';

-- Run once for each invalid result:
-- DROP INDEX CONCURRENTLY <name>;
```

After dropping any invalid indexes, run the migration again.

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
