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

## Execution actions

The detail page and the expanded execution row expose two actions — re-run is always available, and cancel renders only while an execution is `running`. Each posts a form and confirms before acting.

### Re-run

Starts a **new** execution from the stored type and parameters, then redirects to it. The original record is left untouched and stays in the list as history.

The action distinguishes whether graph persistence occurred:

- If the stored class is missing, or today's `configure` signature or graph validation rejects the stored parameters before persistence, no execution is created. The dashboard stays on the source execution and reports the error.
- Once a new graph commits, the dashboard always redirects to that new execution. Deterministic branch or root-start errors are recorded on the affected step and settled through its failure strategy. If an unexpected infrastructure error interrupts startup, the redirect still targets the new execution and says it was created but could not fully start; the underlying error is reported with both source and new pipeline IDs.

This also covers a partial root start: jobs inserted before another root fails remain visible on the newly created execution. Operator-facing messages do not include arbitrary application exception text, which may contain stored parameters or credentials; detailed context remains in Rails error reporting and step failure metadata.

Re-running is not a resumption, and behaves identically whatever the original status was:

- Every step runs again, including steps that already succeeded. There is no in-place retry of a single failed step; re-run is the recovery for a failed execution.
- The DAG is rebuilt from the current class definition, so a re-run picks up code changes made since the original run.
- Pipelines chained onto the original with `.then` are **not** recreated. That topology lives at the original call site rather than in the pipeline class, so a re-run of a chained pipeline runs the pipeline alone.
- Jobs run again in full, so re-running a pipeline with external side effects repeats them.

The two runs are independent records with no stored link between them. Both count toward execution totals and duration percentiles, and the original keeps its `failed` status, so a successful re-run does not clear the failure from the `failed · 7d` KPI.

Each click intentionally creates another independent execution. This is not an exactly-once HTTP operation, but no created execution is hidden behind a redirect to an older record.

One GoodJob interaction to know: retrying a step's **batch** from GoodJob's own dashboard re-runs the job, but the stale completion callback is ignored by GoodPipeline's completion claim, so the retried attempt cannot overwrite a newer attempt's coordination state — its side effects still happen, but the pipeline does not advance from it. Re-run is the supported way to retry.

### Cancel

Offered only while an execution is `running`. Cancelling drains rather than kills, because a job already handed to a GoodJob worker cannot be reliably interrupted:

- Pending steps are skipped immediately.
- Steps already enqueued or executing run to completion.
- The execution stays `running` and shows `canceling…` until the last in-flight step reports back, then settles on `halted`.

A canceled execution reports the `halted` status so existing filters, badges and KPI queries keep working unchanged; the `canceled_at` column is what distinguishes an operator cancel from a failure-driven halt, and the dashboard renders it as `halted · canceled`. Cancelling dispatches the pipeline's `on_complete` and `on_failure` callbacks the same way any other halt does.

Cancelling is claimed with a single conditional `UPDATE`, so a double-clicked button or two operators acting at once produce one cancellation, not two.

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

Existing applications should generate and apply the dashboard indexes and the cancellation column:

```bash
bin/rails generate good_pipeline:upgrade
bin/rails db:migrate
```

The generator creates at most one `add_good_pipeline_dashboard_indexes` migration and one `add_good_pipeline_cancellation` migration, skipping either if it already exists. Indexes are built concurrently and use `if_not_exists`, so the migration is safe to re-run against a database where they already exist. The cancellation migration adds a nullable `canceled_at` column to `good_pipeline_pipelines`. It is required for the upgraded dashboard as a whole, not merely when cancel is clicked: the execution detail and expanded-row views read the column, and settlement consults it on every terminal derivation.

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
