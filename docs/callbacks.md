# Lifecycle Callbacks

Three lifecycle callbacks fire when a pipeline reaches a terminal state.

## Defining callbacks

Register callbacks as class-level methods that name instance methods to invoke:

```ruby
class VideoProcessingPipeline < GoodPipeline::Pipeline
  on_complete :notify_complete   # fires on any terminal state
  on_success  :notify_success    # fires on succeeded
  on_failure  :notify_failure    # fires on failed or halted

  def configure(video_id:)
    run :download, DownloadJob, with: { video_id: video_id }
  end

  private

  def notify_complete
    Rails.logger.info("Pipeline #{id} finished with status: #{status}")
  end

  def notify_success
    Slack.notify("Pipeline #{id} succeeded for video #{params[:video_id]}")
  end

  def notify_failure
    Slack.notify("Pipeline #{id} failed for video #{params[:video_id]}")
  end
end
```

## When each callback fires

| Callback | Fires when pipeline status is |
|---|---|
| `on_complete` | `succeeded`, `failed`, `halted`, or `skipped` |
| `on_success` | `succeeded` |
| `on_failure` | `failed` or `halted` |

Note: `on_failure` does **not** fire for `skipped` pipelines. Being skipped by a chain is not considered a failure — only `on_complete` fires in that case.

## Asynchronous dispatch

Callbacks are dispatched via `PipelineCallbackJob`, a GoodJob job enqueued **in the same transaction** that records the terminal state and executed by GoodJob only after that transaction commits (workers see committed rows only). A slow external call (Slack, webhooks) cannot stall the coordinator, callback execution cannot corrupt pipeline state, and failures remain visible in GoodJob for application-policy or manual retry.

`PipelineCallbackJob` runs on the queue configured by `callback_queue_name` (default: `"good_pipeline_callbacks"`). This is separate from `coordination_queue_name`, which controls `StepFinishedJob`, `PipelineReconciliationJob`, and durable `ChainPropagationJob` handoffs, so slow callbacks don't block pipeline progression. See [Defining Pipelines](/defining-pipelines) for configuration options.

Callback reservation and chain propagation are separate concerns even though both run during terminal settlement. With a valid callback configuration, the terminal status, guarded callback job, and one propagation job per outgoing edge are inserted in the same database transaction, so a process exit immediately after commit loses neither kind of work. Chain propagation is mandatory: failure to persist an edge handoff rolls back settlement. The existing callback-isolation rule is different—a callback adapter/configuration rejection is logged and marks that bundle dispatched rather than preventing the pipeline from settling.

## Exactly-once guarantee

The callback bundle (`on_complete` + one of `on_success`/`on_failure`) is dispatched as a **single unit, exactly once**. A `callbacks_dispatched_at` timestamp is set inside the same `FOR UPDATE` locked transaction that writes the terminal status, so concurrent settlement paths — the coordinator, batch reconciliation, an operator cancel — cannot double-dispatch it.

One boundary of that guarantee is worth knowing: **dispatch is exactly-once; execution is at-least-once.** `PipelineCallbackJob` declares no retry policy of its own, but a crash mid-execution redelivers it, and a raising callback can be retried from GoodJob's dashboard or by an application-configured `retry_on` — any of which re-invokes the whole bundle, including work it partially completed.

[Cancelling](/dashboard#cancel) an execution dispatches the bundle the same way any other halt does, at the single settlement that ends the run.

## Callback failure isolation

If a callback method raises an error:

- The `PipelineCallbackJob` records the failure in GoodJob and can be retried under application policy or from GoodJob's dashboard
- Pipeline status and step statuses are **not** affected
- The pipeline remains in its terminal state
- Other callback methods in the same bundle are still attempted

A callback failure never reopens or alters the terminal pipeline record.
