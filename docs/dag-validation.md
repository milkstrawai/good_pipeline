# DAG Validation

GoodPipeline validates the directed acyclic graph at instantiation time, before any step records are persisted or any jobs are enqueued. If validation fails, `GoodPipeline::InvalidPipelineError` is raised with a descriptive message and nothing is written to the database.

## What is validated

### 1. Empty pipelines

A pipeline with no steps is rejected:

```ruby
class EmptyPipeline < GoodPipeline::Pipeline
  def configure(id:); end
end

EmptyPipeline.run(id: 1)
# => GoodPipeline::InvalidPipelineError: pipeline has no steps
```

### 2. Duplicate step keys

Each step key must be unique within a pipeline:

```ruby
run :download, DownloadJob
run :download, AnotherJob   # same key
# => GoodPipeline::InvalidPipelineError: duplicate step key :download
```

### 3. Unknown `after:` references

Every key in `after:` must correspond to a declared step:

```ruby
run :publish, PublishJob, after: :missing
# => GoodPipeline::InvalidPipelineError: unknown step key :missing
```

Forward references are allowed — the full graph is validated after all `run` calls are collected, not incrementally.

Forward references must stay within the same barrier phase. An earlier phase cannot depend on a step declared after a `barrier`, because that would reverse the phase boundary:

```ruby
run :before, JobA, after: :after
barrier
run :after, JobB
# => GoodPipeline::InvalidPipelineError:
#    step :before cannot depend on later barrier phase step :after
```

### 4. Self-dependencies

A step cannot depend on itself:

```ruby
run :transcode, TranscodeJob, after: :transcode
# => GoodPipeline::InvalidPipelineError: step :transcode depends on itself
```

### 5. Cycles

The graph is checked for cycles using depth-first search. Any cycle causes validation to fail with the cycle path in the error message:

```ruby
run :a, JobA, after: :b
run :b, JobB, after: :a
# => GoodPipeline::InvalidPipelineError: cycle detected: :a -> :b -> :a
```

Indirect cycles are also detected:

```ruby
run :a, JobA, after: :c
run :b, JobB, after: :a
run :c, JobC, after: :b
# => GoodPipeline::InvalidPipelineError: cycle detected: :a -> :c -> :b -> :a
```

### 6. Barrier placement

A barrier must have a nonempty phase on both sides. Leading, trailing, and consecutive barriers are rejected, as are barriers inside branch arms. Generated barrier keys use GoodPipeline's reserved `__good_pipeline_barrier_N` form and cannot collide with user step or branch keys.

Repeated keys in one `after:` list are normalized globally before validation and persistence. This keeps dependency rows and `pending_upstream_count` in agreement.

## Cycle detection algorithm

GoodPipeline uses a recursive depth-first search with a three-color marking scheme:

- **White** — unvisited
- **Grey** — currently in the DFS stack (an ancestor of the current node)
- **Black** — fully processed, confirmed acyclic

If a grey node is encountered during traversal, a cycle is present. The algorithm collects the path for the error message.

## No database writes on failure

Validation runs before any database interaction. If validation fails:

- No `PipelineRecord` is created
- No `StepRecord` rows are inserted
- No `DependencyRecord` edges are written
- No GoodJob batches or jobs are enqueued

This is an intentional design decision: a DAG pipeline gem that allows invalid graphs is not useful.
