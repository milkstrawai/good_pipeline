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
| `on_complete` | `succeeded`, `failed`, `halted`, `skipped`, or `canceled` |
| `on_success` | `succeeded` |
| `on_failure` | `failed` or `halted` |

`skipped` and `canceled` pipelines trigger only `on_complete`; neither outcome is considered a failure. The nonterminal `canceling` state does not trigger callbacks.

## Asynchronous dispatch

Callbacks are dispatched via `PipelineCallbackJob`. The GoodJob row is enqueued in the same database transaction as the terminal pipeline state and becomes runnable after that transaction commits. A slow external call (Slack, webhooks) therefore cannot stall the coordinator, and callback execution cannot corrupt pipeline state.

`PipelineCallbackJob` runs on the queue configured by `callback_queue_name` (default: `"good_pipeline_callbacks"`). This is separate from `coordination_queue_name`, which controls step-finish coordination, so slow callbacks don't block pipeline progression. See [Defining Pipelines](/defining-pipelines) for configuration options.

## Enqueue-once guard and idempotency

The applicable callback bundle (`on_complete`, plus `on_success` or `on_failure` when relevant) is dispatched as a **single job**. A `callbacks_dispatched_at` timestamp is set atomically in the terminal-state transaction, ensuring only one callback job is enqueued even if terminal recomputation is requested more than once.

Job execution itself is not exactly once. An interrupted execution, manual retry, or configured retry can invoke a callback again, so callback methods should be idempotent. `PipelineCallbackJob` does not declare `retry_on`; retry behavior for unhandled errors follows the application's Active Job and GoodJob configuration.

## Callback failure isolation

If a callback method raises an error:

- The `PipelineCallbackJob` fails; whether it is retried depends on the application's Active Job and GoodJob configuration
- Pipeline status and step statuses are **not** affected
- The pipeline remains in its terminal state
- Other callback methods in the same bundle are still attempted

A callback failure never reopens or alters the terminal pipeline record.
