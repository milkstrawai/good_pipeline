# Lifecycle Callbacks

GoodPipeline supports three lifecycle callbacks that fire when a pipeline reaches a terminal state.

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

Callbacks are dispatched via `PipelineCallbackJob`, a GoodJob job enqueued after the terminal state transaction commits. This means:

- A slow external call (Slack, webhooks) cannot stall the coordinator
- Callback execution cannot corrupt pipeline state
- Callbacks benefit from GoodJob's retry mechanism if they fail

## Exactly-once guarantee

The callback bundle (`on_complete` + one of `on_success`/`on_failure`) is dispatched as a **single unit**. A `callbacks_dispatched_at` timestamp is set atomically inside a `FOR UPDATE` locked transaction, ensuring the bundle fires exactly once even if `recompute_pipeline_status` is called from multiple code paths (coordinator or batch reconciliation).

## Callback failure isolation

If a callback method raises an error:

- The `PipelineCallbackJob` fails and is retried by GoodJob
- Pipeline status and step statuses are **not** affected
- The pipeline remains in its terminal state
- Other callback methods in the same bundle are still attempted

Callback delivery failure is an isolated concern that never reopens or alters the terminal pipeline record.
