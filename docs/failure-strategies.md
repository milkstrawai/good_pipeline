# Failure Strategies

GoodPipeline provides three failure strategies that control what happens when a step fails. Strategies can be set at the pipeline level and overridden per step.

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

- That step's **outgoing edges** are treated as non-blocking — its dependents remain eligible
- The pipeline `:halt` policy **still fires** for all other unrelated pending steps
- `halt_triggered` is still set to `true`
- The pipeline still derives to `halted`
:::

Step-level `:ignore` scopes only to that step's outgoing edges, not to the global halt behavior of the pipeline.

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

## Failure resolution table

| Pipeline strategy | Step override | Effect when step fails |
|---|---|---|
| `:halt` | none | `halt_triggered = true`; all pending steps skipped; pipeline → `halted` |
| `:halt` | `:ignore` on failed step | That step's dependents still eligible; all other pending steps still skipped; pipeline → `halted` |
| `:continue` | none | Permanently unsatisfied descendants skipped; pipeline → `failed` |
| `:continue` | `:ignore` on failed step | That step's dependents still eligible |
| `:ignore` | none | Nothing skipped; pipeline → `failed` if any step failed |
