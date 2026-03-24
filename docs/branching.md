# Conditional Branching

GoodPipeline supports conditional branching — taking different paths at runtime based on application state. Branches are rendered as diamond decision nodes in the dashboard.

## Defining a branch

Use `branch` inside `configure` to define a decision point. The `by:` option names a method on your pipeline class that returns the arm to execute:

```ruby
class MediaPipeline < GoodPipeline::Pipeline
  def configure(media_id:)
    run :analyze, AnalyzeJob, with: { media_id: media_id }

    branch :format_check, after: :analyze, by: :detect_format do
      on :hd do
        run :transcode_hd, TranscodeHDJob, with: { media_id: media_id }
        run :upscale, UpscaleJob, with: { media_id: media_id }, after: :transcode_hd
      end

      on :sd do
        run :transcode_sd, TranscodeSDJob, with: { media_id: media_id }
      end
    end

    run :publish, PublishJob, after: :format_check
  end

  private

  def detect_format
    Media.find(params[:media_id]).hd? ? :hd : :sd
  end
end
```

## How it works

1. When the branch step's upstream dependencies are satisfied, the coordinator evaluates the `by:` method
2. The method returns a symbol (`:hd`, `:sd`, etc.) that selects which arm to run
3. Steps in the matching arm are enqueued normally
4. Steps in non-matching arms are marked `skipped_by_branch` — a terminal status that counts as **satisfied** for downstream dependency resolution
5. `after: :format_check` waits for whichever arm was chosen to complete before proceeding

The decision method has access to `params` and can query any application state (database, cache, external APIs). It runs once per branch per pipeline execution — the result is cached.

## Multiple steps per arm

Each arm can contain multiple steps with their own `after:` dependencies:

```ruby
branch :deploy_strategy, after: :run_tests, by: :pick_strategy do
  on :canary do
    run :canary_deploy,  CanaryDeployJob
    run :canary_monitor, CanaryMonitorJob, after: :canary_deploy
    run :canary_promote, CanaryPromoteJob, after: :canary_monitor
  end

  on :blue_green do
    run :swap,   BlueGreenSwapJob
    run :verify, BlueGreenVerifyJob, after: :swap
  end
end
```

## Empty arms (if without else)

Arms can be empty for cases where one path does nothing:

```ruby
branch :quality_check, after: :analyze, by: :needs_processing do
  on :yes do
    run :process,  ProcessJob
    run :enhance,  EnhanceJob, after: :process
  end
  on :no  # skip — pipeline continues to next step
end

run :save, SaveJob, after: :quality_check
```

When the decision returns `:no`, all `:yes` arm steps are skipped and `:save` proceeds directly. The dashboard shows the empty arm as a direct edge from the diamond to the next step.

## Multiple branches

Pipelines can have multiple branches in sequence:

```ruby
def configure(content_id:)
  run :ingest, IngestJob, with: { content_id: content_id }

  branch :classify, after: :ingest, by: :content_type do
    on :text do
      run :extract_text, ExtractTextJob
      run :run_nlp, RunNlpJob, after: :extract_text
    end
    on :image do
      run :detect_objects, DetectObjectsJob
      run :check_nsfw, CheckNsfwJob, after: :detect_objects
    end
  end

  branch :priority, after: :classify, by: :review_priority do
    on :high do
      run :fast_review, FastReviewJob
    end
    on :low do
      run :standard_review, StandardReviewJob
    end
  end

  run :publish, PublishJob, after: :priority
end
```

Each branch decides independently. The second branch runs after whichever arm of the first branch completes.

## Error handling

If the decision method returns a value that does not match any declared arm (including empty arms), the branch step is marked `failed` with a `ConfigurationError`. The error class and message are stored on the step record and the pipeline proceeds through normal failure propagation (`:halt`, `:continue`, or `:ignore` depending on strategy).

```ruby
branch :check, after: :analyze, by: :pick do
  on(:hd) { run :transcode_hd, TranscodeHDJob }
  on(:sd) { run :transcode_sd, TranscodeSDJob }
end

# If pick returns :unknown → branch step fails with:
# "branch :check decision returned "unknown", but only :hd, :sd are declared"
```

## Limitations

- **Nested branches** (a branch inside another branch's arm) are not supported. This is validated and rejected with a `ConfigurationError`.
- **Branch order matters** — define branches before referencing them in `after:`. A `run` with `after: :branch_key` must appear after the `branch` definition.
- **Decision methods must be fast** — they run inside the coordinator's step processing. Avoid slow external calls.
