# Failure Strategies

Three failure strategies control what happens when a step fails. Set one at the pipeline level, then override per step if needed.

## Pipeline-level strategy

Set with `failure_strategy` in the pipeline class body:

```ruby
class MyPipeline < GoodPipeline::Pipeline
  failure_strategy :continue  # :halt (default), :continue, or :ignore
end
```

### `:halt` (default)

When any step fails, the coordinator sets `halt_triggered = true` and marks all remaining `pending` steps as `skipped`. The pipeline derives to `halted`.

```ruby
class HaltPipeline < GoodPipeline::Pipeline
  failure_strategy :halt

  def configure(id:)
    run :a, JobA, with: { id: id }
    run :b, JobB, with: { id: id }  # independent of :a
    run :c, JobC, after: :a
  end
end
```

If `:a` fails: `:b` is skipped (even though it's independent), `:c` is skipped, pipeline status is `halted`.

### `:continue`

The coordinator applies skip propagation only to permanently unsatisfied descendants. Independent branches continue executing. The pipeline derives to `failed`.

```ruby
class ContinuePipeline < GoodPipeline::Pipeline
  failure_strategy :continue

  def configure(id:)
    run :a, JobA, with: { id: id }
    run :b, JobB, with: { id: id }  # independent of :a
    run :c, JobC, after: :a
  end
end
```

If `:a` fails: `:c` is skipped (depends on `:a`), `:b` still runs, pipeline status is `failed`.

### `:ignore`

Treats all failed steps as satisfied for dependency resolution. Nothing is skipped. The pipeline derives to `failed` if any step actually failed.

```ruby
class IgnorePipeline < GoodPipeline::Pipeline
  failure_strategy :ignore

  def configure(id:)
    run :a, JobA, with: { id: id }
    run :b, JobB, after: :a
  end
end
```

If `:a` fails: `:b` is still enqueued (failure treated as success for dependencies), pipeline status is `failed`.

## Step-level override

Override the failure strategy for a specific step's **outgoing edges** using `on_failure:` in the `run` call:

```ruby
run :thumbnail, ThumbnailJob,
  after:      :download,
  on_failure: :ignore   # thumbnail failure never blocks downstream steps
```

Step-level `on_failure` takes precedence over the pipeline-level strategy for that step's outgoing edges only.

## Effective strategy resolution

The coordinator resolves the effective strategy for each step's outgoing edges:

1. If the step has a step-level `on_failure:` override, use that
2. Otherwise, fall back to the pipeline-level `failure_strategy`

## The `:halt` + step `:ignore` interaction

::: warning Important
When a step fails with step-level `on_failure: :ignore` under a pipeline-level `:halt` strategy, the behavior may be surprising:

- That step's **entire downstream subgraph** is treated as non-blocking — its dependents and their transitive descendants remain eligible
- The pipeline `:halt` policy **still fires** for all other unrelated pending steps
- `halt_triggered` is still set to `true`
- The pipeline still derives to `halted`
:::

Step-level `:ignore` protects the full reachable downstream path from the ignored step, not just its immediate dependents. This ensures that if `A(ignore) -> B -> C`, both `B` and `C` remain eligible when `A` fails.

```ruby
class MixedPipeline < GoodPipeline::Pipeline
  failure_strategy :halt

  def configure(id:)
    run :optional, OptionalJob, with: { id: id }, on_failure: :ignore
    run :required, RequiredJob, with: { id: id }
    run :after_optional, AfterOptionalJob, after: :optional
  end
end
```

If `:optional` fails: `:after_optional` remains eligible (ignore override), `:required` is skipped (halt policy), pipeline is `halted`.

## Dependency satisfaction rules

A dependency edge (upstream → downstream) is **satisfied** when:

| Upstream status | Upstream strategy | Edge satisfied? |
|---|---|---|
| `succeeded` | any | Yes |
| `failed` | `:ignore` | Yes — treated as non-blocking |
| `failed` | `:continue` or `:halt` | No |
| `skipped` | any | No |
| `pending` or `enqueued` | any | No — not yet terminal |

A downstream step is eligible for enqueue when **all** of its incoming edges are satisfied.

A downstream step is marked `skipped` when it's still `pending` and at least one incoming edge is **permanently unsatisfied** — the upstream is terminal, cannot satisfy the edge, and no future event can change that.

Ordinary `skipped` and `canceled` upstream steps are always permanently unsatisfied, regardless of an inherited `:ignore` strategy. `skipped_by_branch` is different: it represents an unselected conditional path and counts as satisfied.

## Failure behavior across a barrier

A barrier depends on every step in its preceding phase, so the same rules apply at the phase boundary:

- A failed phase step using `:ignore` satisfies the barrier edge.
- A failed phase step using `:continue` makes the barrier and its later phase `skipped`.
- Pipeline-level `:halt` skips pending work. If the failed step has a step-level `:ignore`, its downstream subtree remains protected, but unrelated phase paths may be skipped. Any ordinarily skipped phase step still blocks the barrier, so the barrier skips rather than continuing.
- Cancellation cancels a pending barrier and its later phase.

Whenever eligible work remains, every new terminal step releases its outgoing dependency counter exactly once. This includes enqueue-time configuration failures and steps skipped by partial halt propagation, preventing a barrier or ordinary fan-in from remaining pending after all upstreams are terminal.

## Early termination with success

Sometimes a job determines there is nothing to do — the account is deactivated, the resource was already processed, etc. Call `halt_pipeline!` to stop the pipeline early and mark it as `succeeded`:

```ruby
class FetchDataJob < ApplicationJob
  def perform(account_id:)
    account = Account.find(account_id)
    return halt_pipeline! if account.deactivated?

    # ... normal work
  end
end
```

The behavior:

| Aspect | Value |
|---|---|
| Halting step status | `halted` |
| Remaining pending steps | `skipped` |
| Pipeline status | `succeeded` |
| Callback triggered | `on_success` |
| GoodJob record | Succeeded (no error, no discard) |

No configuration or module includes are required. The Engine includes `GoodPipeline::Haltable` into `ActiveJob::Base` at boot, so `halt_pipeline!` is available in any job. For non-pipeline jobs, it's a no-op.

::: tip Return early
Remember to use `return halt_pipeline!` — without `return`, the job continues executing after the call.
:::

::: warning Parallel steps
If another step is already running when `halt_pipeline!` is called, that step continues to completion. Only `pending` steps are skipped. If the running step fails, the pipeline will derive to `failed`, not `succeeded`.
:::

## Dashboard cancellation

Dashboard cancellation is separate from the pipeline's failure strategy. It stops future DAG scheduling rather than force-terminating work: pending steps become `canceled`, while jobs already enqueued, scheduled, or retrying run normally and keep their actual `succeeded`, `failed`, or `halted` step outcomes. While the pipeline is `canceling`, those outcomes do not trigger halt propagation or enqueue downstream steps.

`canceling` is active and nonterminal. The pipeline becomes terminal `canceled` only after all enqueued work reaches a terminal outcome, so it may remain `canceling` indefinitely if a job never finishes. A canceled pipeline fires `on_complete`, but cancellation is not a failure and does not fire `on_failure`.

## Failure resolution table

| Pipeline strategy | Step override | Effect when step fails |
|---|---|---|
| `:halt` | none | `halt_triggered = true`; all pending steps skipped; pipeline → `halted` |
| `:halt` | `:ignore` on failed step | That step's full downstream subgraph still eligible; all other pending steps still skipped; pipeline → `halted` |
| `:continue` | none | Permanently unsatisfied descendants skipped; pipeline → `failed` |
| `:continue` | `:ignore` on failed step | That step's dependents still eligible |
| `:ignore` | none | Nothing skipped; pipeline → `failed` if any step failed |
