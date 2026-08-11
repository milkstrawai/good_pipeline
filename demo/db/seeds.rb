# frozen_string_literal: true

require "securerandom"

puts "Seeding GoodPipeline demo data..."

SEED_JOB_QUEUE = "good_pipeline_demo_seed"
SEED_FUTURE = Time.utc(2100, 1, 1)
NOW = Time.current.change(usec: 0)

# GoodJob rows have no foreign key from GoodPipeline, so tag synthetic rows by
# queue name and remove them explicitly before rebuilding the demo fixtures.
GoodJob::Job.where(queue_name: SEED_JOB_QUEUE).delete_all
GoodPipeline::ChainRecord.delete_all
GoodPipeline::DependencyRecord.delete_all
GoodPipeline::StepRecord.delete_all
GoodPipeline::PipelineRecord.delete_all

def create_pipeline(type:, status:, params:, strategy: "halt", age: nil, created_at: nil, duration: nil,
                    halt_triggered: false)
  timestamp = created_at || (NOW - age)
  pipeline = GoodPipeline::PipelineRecord.create!(
    type: type, status: status, params: params,
    on_failure_strategy: strategy, halt_triggered: halt_triggered
  )
  pipeline.update_columns(
    created_at: timestamp,
    updated_at: duration ? timestamp + duration : timestamp
  )
  pipeline
end

def active_job_payload(job_id:, job_class:, scheduled_at:, enqueued_at:)
  {
    "job_class" => job_class,
    "job_id" => job_id,
    "provider_job_id" => job_id,
    "queue_name" => SEED_JOB_QUEUE,
    "priority" => 0,
    "arguments" => [],
    "executions" => 0,
    "exception_executions" => {},
    "locale" => "en",
    "timezone" => "UTC",
    "enqueued_at" => enqueued_at.utc.iso8601(9),
    "scheduled_at" => scheduled_at.utc.iso8601(9)
  }
end

def create_seed_job(job_class:, state:, created_at:, duration:, error: nil)
  job_id = SecureRandom.uuid
  unfinished = %i[running queued].include?(state)
  scheduled_at = unfinished ? SEED_FUTURE : created_at
  performed_at = %i[completed running].include?(state) ? created_at : nil
  finished_at = state == :completed ? created_at + duration : nil

  GoodJob::Job.create!(
    id: job_id,
    active_job_id: job_id,
    queue_name: SEED_JOB_QUEUE,
    priority: 0,
    serialized_params: active_job_payload(
      job_id: job_id,
      job_class: job_class,
      scheduled_at: scheduled_at,
      enqueued_at: created_at
    ),
    scheduled_at: scheduled_at,
    performed_at: performed_at,
    finished_at: finished_at,
    error: error,
    executions_count: state == :queued ? 0 : 1,
    job_class: job_class,
    created_at: created_at,
    updated_at: finished_at || created_at
  )
end

def inferred_job_state(status)
  case status
  when "succeeded", "failed", "halted" then :completed
  when "enqueued" then :queued
  else :none
  end
end

def add_steps(pipeline, *step_defs)
  records = {}
  step_defs.each_with_index do |definition, index|
    branch_hash = definition.slice(:decides, :branch_result, :empty_arms, :branch_key, :branch_arm).transform_keys(&:to_s)
    status = definition.fetch(:status, "succeeded")
    job_state = definition.fetch(:job_state, inferred_job_state(status))
    started_at = pipeline.created_at + definition.fetch(:start_after, (index + 1) * 5).seconds
    job_duration = definition.fetch(:duration, 10).seconds
    error = if status == "failed"
              "#{definition.fetch(:error_class, 'RuntimeError')}: #{definition.fetch(:error_message, 'Synthetic failure')}"
            end
    good_job = if %i[completed running queued].include?(job_state)
                 create_seed_job(
                   job_class: definition[:job], state: job_state, created_at: started_at,
                   duration: job_duration, error: error
                 )
               end
    good_job_id = job_state == :dangling ? SecureRandom.uuid : good_job&.id

    records[definition[:key]] = GoodPipeline::StepRecord.create!(
      pipeline: pipeline, key: definition[:key], job_class: definition[:job],
      coordination_status: status, good_job_id: good_job_id,
      error_class: definition[:error_class], error_message: definition[:error_message],
      branch: branch_hash,
      created_at: pipeline.created_at + index.fdiv(1_000_000),
      updated_at: pipeline.created_at + index.fdiv(1_000_000)
    )
  end
  records
end

def add_edges(pipeline, steps, *edges)
  edges.each do |from, to|
    GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: steps[to], depends_on_step: steps[from])
  end
  normalize_job_timings(pipeline)
end

def normalize_job_timings(pipeline)
  ordered_steps = pipeline.steps.order(:created_at, :id).to_a
  dependencies = pipeline.dependencies.to_a
  jobs = GoodJob::Job.where(id: ordered_steps.filter_map(&:good_job_id)).index_by(&:id)
  parents = dependencies.group_by(&:step_id).transform_values do |records|
    records.map(&:depends_on_step_id)
  end
  by_id = ordered_steps.index_by(&:id)
  remaining = ordered_steps.to_h { |step| [step.id, parents.fetch(step.id, []).length] }
  children = dependencies.group_by(&:depends_on_step_id)
  ready = ordered_steps.select { |step| remaining.fetch(step.id).zero? }

  until ready.empty?
    step = ready.shift
    job = jobs[step.good_job_id]
    upstream_finishes = parents.fetch(step.id, []).filter_map do |id|
      upstream = by_id[id]
      jobs[upstream&.good_job_id]&.finished_at
    end
    shift_seed_job_after(job, upstream_finishes.max) if job&.performed_at && upstream_finishes.any?

    children.fetch(step.id, []).each do |dependency|
      remaining[dependency.step_id] -= 1
      ready << by_id.fetch(dependency.step_id) if remaining.fetch(dependency.step_id).zero?
    end
  end
end

def shift_seed_job_after(job, earliest_start)
  return unless earliest_start && job.performed_at < earliest_start

  duration = job.finished_at && (job.finished_at - job.performed_at)
  attributes = { performed_at: earliest_start }
  attributes[:finished_at] = earliest_start + duration if duration
  if job.finished_at
    attributes[:scheduled_at] = earliest_start
    attributes[:updated_at] = attributes[:finished_at]
    payload = job.serialized_params.deep_dup
    payload["enqueued_at"] = earliest_start.utc.iso8601(9)
    payload["scheduled_at"] = earliest_start.utc.iso8601(9)
    attributes[:serialized_params] = payload
  end
  job.update_columns(attributes)
end

def recent_seed_time(day_offset, slot)
  day_start = NOW.beginning_of_day - day_offset.days
  return day_start + (30 + (slot * 73)).minutes unless day_offset.zero?

  # Always stay inside today's calendar bucket without creating future rows,
  # including when seeds run just after midnight.
  elapsed = [(NOW - day_start).to_i - 1, 0].max
  offset = elapsed.zero? ? 0 : ((slot + 1) * elapsed / 14.0).floor
  day_start + [offset, elapsed].min.seconds
end

# 1. VideoProcessingPipeline (succeeded) — fan-out + fan-in DAG
video = create_pipeline(type: "VideoProcessingPipeline", status: "succeeded",
                         params: { video_id: 8842, format: "mp4", resolution: "1080p" }, age: 2.hours, duration: 1.hour)
video_steps = add_steps(video,
                        { key: "download", job: "DownloadJob" },
                        { key: "transcode", job: "TranscodeJob" },
                        { key: "thumbnail", job: "ThumbnailJob" },
                        { key: "publish", job: "PublishJob" },
                        { key: "cleanup", job: "CleanupJob" })
add_edges(video, video_steps,
          %w[download transcode], %w[download thumbnail],
          %w[transcode publish], %w[thumbnail publish],
          %w[publish cleanup])

# 2. DataIngestionPipeline (succeeded) — linear chain
ingest = create_pipeline(type: "DataIngestionPipeline", status: "succeeded",
                          params: { source: "s3://data-lake/events/2026-03-20", dataset: "user_events" },
                          strategy: "continue", age: 5.hours, duration: 1.hour)
ingest_steps = add_steps(ingest,
                         { key: "extract", job: "ExtractJob" }, { key: "validate", job: "ValidateJob" },
                         { key: "transform", job: "TransformJob" }, { key: "load", job: "LoadJob" })
add_edges(ingest, ingest_steps, %w[extract validate], %w[validate transform], %w[transform load])

# 3. ReportGenerationPipeline (running) — partially complete
report = create_pipeline(type: "ReportGenerationPipeline", status: "running",
                          params: { report_type: "monthly_revenue", month: "2026-02" }, age: 15.minutes)
report_steps = add_steps(report,
                         { key: "query_data", job: "QueryDataJob" },
                         { key: "aggregate", job: "AggregateJob", status: "enqueued", job_state: :running },
                         { key: "render_pdf", job: "RenderPdfJob", status: "pending" },
                         { key: "email_report", job: "EmailReportJob", status: "pending" })
add_edges(report, report_steps, %w[query_data aggregate], %w[aggregate render_pdf], %w[render_pdf email_report])

# 4. UserOnboardingPipeline (succeeded) — fan-out
onboarding = create_pipeline(type: "UserOnboardingPipeline", status: "succeeded",
                              params: { user_id: 29_451, plan: "pro" }, age: 30.minutes, duration: 5.minutes)
onboarding_steps = add_steps(onboarding,
                             { key: "provision_account", job: "ProvisionAccountJob" },
                             { key: "send_welcome_email", job: "SendWelcomeEmailJob" },
                             { key: "sync_crm", job: "SyncCrmJob" })
add_edges(onboarding, onboarding_steps, %w[provision_account send_welcome_email], %w[provision_account sync_crm])

# 5. PaymentReconciliationPipeline (failed) — with error
payment = create_pipeline(type: "PaymentReconciliationPipeline", status: "failed",
                           params: { batch_date: "2026-03-19", gateway: "stripe" },
                           strategy: "continue", age: 1.hour, duration: 15.minutes)
payment_steps = add_steps(payment,
                          { key: "fetch_transactions", job: "FetchTransactionsJob" },
                          { key: "match_records", job: "MatchRecordsJob", status: "failed",
                            error_class: "ReconciliationError",
                            error_message: "Found 23 unmatched transactions totaling $4,892.50" },
                          { key: "generate_report", job: "GenerateReportJob", status: "skipped" })
add_edges(payment, payment_steps, %w[fetch_transactions match_records], %w[match_records generate_report])

# 6. OrderFulfillmentPipeline → CustomerNotificationPipeline (chain)
order = create_pipeline(type: "OrderFulfillmentPipeline", status: "succeeded",
                         params: { order_id: 78_332, warehouse: "us-east-1" }, age: 3.hours, duration: 30.minutes)
order_steps = add_steps(order,
                        { key: "reserve_inventory", job: "ReserveInventoryJob" },
                        { key: "pick_and_pack", job: "PickAndPackJob" },
                        { key: "ship", job: "ShipJob" },
                        { key: "update_tracking", job: "UpdateTrackingJob" })
add_edges(order, order_steps,
          %w[reserve_inventory pick_and_pack], %w[pick_and_pack ship], %w[ship update_tracking])

notify = create_pipeline(type: "CustomerNotificationPipeline", status: "succeeded",
                          params: { order_id: 78_332, channel: "email" }, age: 2.5.hours, duration: 30.minutes)
add_steps(notify, { key: "send_shipping_email", job: "SendShippingEmailJob" }, { key: "send_sms", job: "SendSmsJob" })
GoodPipeline::ChainRecord.create!(upstream_pipeline: order, downstream_pipeline: notify)

# 7. ImageResizePipeline (halted) — first step failed
image = create_pipeline(type: "ImageResizePipeline", status: "halted", halt_triggered: true,
                         params: { image_id: 55_210, sizes: %w[sm md lg xl] }, age: 45.minutes, duration: 5.minutes)
image_steps = add_steps(image,
                        { key: "download_original", job: "DownloadOriginalJob", status: "failed",
                          error_class: "Aws::S3::Errors::NoSuchKey", error_message: "The specified key does not exist." },
                        { key: "resize", job: "ResizeJob", status: "skipped" },
                        { key: "upload_resized", job: "UploadResizedJob", status: "skipped" })
add_edges(image, image_steps, %w[download_original resize], %w[resize upload_resized])

# 8. InvoiceProcessingPipeline (succeeded) — linear chain
invoice = create_pipeline(type: "InvoiceProcessingPipeline", status: "succeeded",
                           params: { invoice_id: 11_298, vendor: "Acme Corp" }, age: 6.hours, duration: 30.minutes)
invoice_steps = add_steps(invoice,
                          { key: "parse_pdf", job: "ParsePdfJob" }, { key: "validate_line_items", job: "ValidateLineItemsJob" },
                          { key: "auto_approve", job: "AutoApproveJob" }, { key: "post_to_ledger", job: "PostToLedgerJob" })
add_edges(invoice, invoice_steps, %w[parse_pdf validate_line_items], %w[validate_line_items auto_approve], %w[auto_approve post_to_ledger])

# 9. VideoProcessingPipeline (succeeded, older) — second execution
video2 = create_pipeline(type: "VideoProcessingPipeline", status: "succeeded",
                          params: { video_id: 7_651, format: "webm", resolution: "720p" }, age: 8.hours, duration: 1.hour)
video2_steps = add_steps(video2,
                         { key: "download", job: "DownloadJob" }, { key: "transcode", job: "TranscodeJob" },
                         { key: "thumbnail", job: "ThumbnailJob" }, { key: "publish", job: "PublishJob" },
                         { key: "cleanup", job: "CleanupJob" })
add_edges(video2, video2_steps,
          %w[download transcode], %w[download thumbnail],
          %w[transcode publish], %w[thumbnail publish],
          %w[publish cleanup])

# 10. DataIngestionPipeline (running) — just started
ingest2 = create_pipeline(type: "DataIngestionPipeline", status: "running",
                           params: { source: "s3://data-lake/events/2026-03-21", dataset: "page_views" },
                           strategy: "continue", age: 3.minutes)
ingest2_steps = add_steps(ingest2,
                          { key: "extract", job: "ExtractJob" },
                          { key: "validate", job: "ValidateJob", status: "enqueued", job_state: :queued },
                          { key: "transform", job: "TransformJob", status: "pending" },
                          { key: "load", job: "LoadJob", status: "pending" })
add_edges(ingest2, ingest2_steps, %w[extract validate], %w[validate transform], %w[transform load])

# 11. MediaProcessingPipeline (succeeded, HD path taken) — single branch
branch_job = GoodPipeline::BRANCH_JOB_CLASS
media = create_pipeline(type: "MediaProcessingPipeline", status: "succeeded",
                         params: { media_id: 4421, source: "upload" }, age: 1.hour, duration: 20.minutes)
media_steps = add_steps(media,
                        { key: "analyze", job: "AnalyzeJob" },
                        { key: "format_check", job: branch_job, decides: "detect_format", branch_result: "hd" },
                        { key: "transcode_hd", job: "TranscodeHDJob", branch_key: "format_check", branch_arm: "hd" },
                        { key: "upscale", job: "UpscaleJob", branch_key: "format_check", branch_arm: "hd" },
                        { key: "transcode_sd", job: "TranscodeSDJob", branch_key: "format_check", branch_arm: "sd",
                          status: "skipped_by_branch" },
                        { key: "publish", job: "PublishJob" })
add_edges(media, media_steps,
          %w[analyze format_check],
          %w[format_check transcode_hd], %w[format_check transcode_sd],
          %w[transcode_hd upscale],
          %w[upscale publish], %w[transcode_sd publish])

# 12. DeploymentPipeline (succeeded, canary path) — branch with multi-step arms
deploy = create_pipeline(type: "DeploymentPipeline", status: "succeeded",
                          params: { service: "api-gateway", version: "2.4.1", env: "production" },
                          age: 4.hours, duration: 45.minutes)
deploy_steps = add_steps(deploy,
                         { key: "build", job: "BuildJob" },
                         { key: "run_tests", job: "RunTestsJob" },
                         { key: "deploy_strategy", job: branch_job, decides: "pick_strategy", branch_result: "canary" },
                         { key: "canary_deploy", job: "CanaryDeployJob", branch_key: "deploy_strategy", branch_arm: "canary" },
                         { key: "canary_monitor", job: "CanaryMonitorJob", branch_key: "deploy_strategy", branch_arm: "canary" },
                         { key: "canary_promote", job: "CanaryPromoteJob", branch_key: "deploy_strategy", branch_arm: "canary" },
                         { key: "blue_green_swap", job: "BlueGreenSwapJob", branch_key: "deploy_strategy", branch_arm: "blue_green",
                           status: "skipped_by_branch" },
                         { key: "blue_green_verify", job: "BlueGreenVerifyJob", branch_key: "deploy_strategy", branch_arm: "blue_green",
                           status: "skipped_by_branch" },
                         { key: "notify_team", job: "NotifyTeamJob" })
add_edges(deploy, deploy_steps,
          %w[build run_tests], %w[run_tests deploy_strategy],
          %w[deploy_strategy canary_deploy], %w[deploy_strategy blue_green_swap],
          %w[canary_deploy canary_monitor], %w[canary_monitor canary_promote],
          %w[blue_green_swap blue_green_verify],
          %w[canary_promote notify_team], %w[blue_green_verify notify_team])

# 13. MediaProcessingPipeline (succeeded, SD path) — same pipeline type, different branch result
media2 = create_pipeline(type: "MediaProcessingPipeline", status: "succeeded",
                          params: { media_id: 4422, source: "api" }, age: 30.minutes, duration: 10.minutes)
media2_steps = add_steps(media2,
                         { key: "analyze", job: "AnalyzeJob" },
                         { key: "format_check", job: branch_job, decides: "detect_format", branch_result: "sd" },
                         { key: "transcode_hd", job: "TranscodeHDJob", branch_key: "format_check", branch_arm: "hd",
                           status: "skipped_by_branch" },
                         { key: "upscale", job: "UpscaleJob", branch_key: "format_check", branch_arm: "hd",
                           status: "skipped_by_branch" },
                         { key: "transcode_sd", job: "TranscodeSDJob", branch_key: "format_check", branch_arm: "sd" },
                         { key: "publish", job: "PublishJob" })
add_edges(media2, media2_steps,
          %w[analyze format_check],
          %w[format_check transcode_hd], %w[format_check transcode_sd],
          %w[transcode_hd upscale],
          %w[upscale publish], %w[transcode_sd publish])

# 14. ContentModerationPipeline (succeeded) — two sequential branches
#   ingest → classify_content(branch: text/image) → [text arm / image arm] →
#   review_priority(branch: high/low) → [fast review / standard review] → publish
moderation = create_pipeline(type: "ContentModerationPipeline", status: "succeeded",
                              params: { content_id: 99_201, source: "user_upload" },
                              age: 2.hours, duration: 35.minutes)
moderation_steps = add_steps(moderation,
                             { key: "ingest", job: "IngestContentJob" },
                             # First branch: content type
                             { key: "classify_content", job: branch_job, decides: "detect_content_type",
                               branch_result: "image" },
                             { key: "extract_text", job: "ExtractTextJob",
                               branch_key: "classify_content", branch_arm: "text", status: "skipped_by_branch" },
                             { key: "run_nlp", job: "RunNlpJob",
                               branch_key: "classify_content", branch_arm: "text", status: "skipped_by_branch" },
                             { key: "detect_objects", job: "DetectObjectsJob",
                               branch_key: "classify_content", branch_arm: "image" },
                             { key: "check_nsfw", job: "CheckNsfwJob",
                               branch_key: "classify_content", branch_arm: "image" },
                             # Second branch: review priority
                             { key: "review_priority", job: branch_job, decides: "determine_priority",
                               branch_result: "low" },
                             { key: "fast_review", job: "FastReviewJob",
                               branch_key: "review_priority", branch_arm: "high", status: "skipped_by_branch" },
                             { key: "standard_review", job: "StandardReviewJob",
                               branch_key: "review_priority", branch_arm: "low" },
                             { key: "publish_content", job: "PublishContentJob" })
add_edges(moderation, moderation_steps,
          %w[ingest classify_content],
          %w[classify_content extract_text], %w[classify_content detect_objects],
          %w[extract_text run_nlp],
          %w[detect_objects check_nsfw],
          # Both arms feed into second branch
          %w[run_nlp review_priority], %w[check_nsfw review_priority],
          %w[review_priority fast_review], %w[review_priority standard_review],
          %w[fast_review publish_content], %w[standard_review publish_content])

# 15. DataEnrichmentPipeline (succeeded, skip arm taken) — branch with empty arm
enrichment = create_pipeline(type: "DataEnrichmentPipeline", status: "succeeded",
                              params: { record_id: 33_100, source: "api" },
                              age: 20.minutes, duration: 8.minutes)
enrichment_steps = add_steps(enrichment,
                             { key: "fetch_record", job: "FetchRecordJob" },
                             { key: "quality_check", job: branch_job, decides: "needs_enrichment",
                               branch_result: "skip", empty_arms: %w[skip] },
                             { key: "geocode", job: "GeocodeJob",
                               branch_key: "quality_check", branch_arm: "enrich", status: "skipped_by_branch" },
                             { key: "normalize", job: "NormalizeJob",
                               branch_key: "quality_check", branch_arm: "enrich", status: "skipped_by_branch" },
                             { key: "save_record", job: "SaveRecordJob" })
add_edges(enrichment, enrichment_steps,
          %w[fetch_record quality_check],
          %w[quality_check geocode],
          %w[geocode normalize],
          %w[normalize save_record])

# 16. DataEnrichmentPipeline (succeeded, enrich arm taken) — same type, different path
enrichment2 = create_pipeline(type: "DataEnrichmentPipeline", status: "succeeded",
                               params: { record_id: 33_101, source: "upload" },
                               age: 10.minutes, duration: 15.minutes)
enrichment2_steps = add_steps(enrichment2,
                              { key: "fetch_record", job: "FetchRecordJob" },
                              { key: "quality_check", job: branch_job, decides: "needs_enrichment",
                                branch_result: "enrich", empty_arms: %w[skip] },
                              { key: "geocode", job: "GeocodeJob",
                                branch_key: "quality_check", branch_arm: "enrich" },
                              { key: "normalize", job: "NormalizeJob",
                                branch_key: "quality_check", branch_arm: "enrich" },
                              { key: "save_record", job: "SaveRecordJob" })
add_edges(enrichment2, enrichment2_steps,
          %w[fetch_record quality_check],
          %w[quality_check geocode],
          %w[geocode normalize],
          %w[normalize save_record])

# 17. OrderRoutingPipeline (succeeded, skip on first branch, process on second) — 2 sequential branches with empty arms
routing = create_pipeline(type: "OrderRoutingPipeline", status: "succeeded",
                           params: { order_id: 50_100, region: "eu" },
                           age: 40.minutes, duration: 12.minutes)
routing_steps = add_steps(routing,
                          { key: "receive_order", job: "ReceiveOrderJob" },
                          # First branch: fraud check — skip (no fraud)
                          { key: "fraud_check", job: branch_job, decides: "check_fraud",
                            branch_result: "safe", empty_arms: %w[safe] },
                          { key: "manual_review", job: "ManualReviewJob",
                            branch_key: "fraud_check", branch_arm: "suspicious",
                            status: "skipped_by_branch" },
                          { key: "flag_account", job: "FlagAccountJob",
                            branch_key: "fraud_check", branch_arm: "suspicious",
                            status: "skipped_by_branch" },
                          # Second branch: shipping method
                          { key: "shipping_method", job: branch_job, decides: "pick_shipping",
                            branch_result: "express", empty_arms: %w[pickup] },
                          { key: "schedule_courier", job: "ScheduleCourierJob",
                            branch_key: "shipping_method", branch_arm: "express" },
                          { key: "generate_label", job: "GenerateLabelJob",
                            branch_key: "shipping_method", branch_arm: "express" },
                          { key: "notify_warehouse", job: "NotifyWarehouseJob",
                            branch_key: "shipping_method", branch_arm: "standard",
                            status: "skipped_by_branch" },
                          { key: "send_confirmation", job: "SendConfirmationJob" })
add_edges(routing, routing_steps,
          %w[receive_order fraud_check],
          %w[fraud_check manual_review], %w[manual_review flag_account],
          # First branch exit → second branch
          %w[flag_account shipping_method],
          %w[shipping_method schedule_courier], %w[shipping_method notify_warehouse],
          %w[schedule_courier generate_label],
          %w[generate_label send_confirmation], %w[notify_warehouse send_confirmation])

# 18. OrderRoutingPipeline (succeeded, suspicious + pickup) — both empty arms skipped through
routing2 = create_pipeline(type: "OrderRoutingPipeline", status: "succeeded",
                            params: { order_id: 50_101, region: "us" },
                            age: 25.minutes, duration: 18.minutes)
routing2_steps = add_steps(routing2,
                           { key: "receive_order", job: "ReceiveOrderJob" },
                           # First branch: fraud — suspicious path taken
                           { key: "fraud_check", job: branch_job, decides: "check_fraud",
                             branch_result: "suspicious", empty_arms: %w[safe] },
                           { key: "manual_review", job: "ManualReviewJob",
                             branch_key: "fraud_check", branch_arm: "suspicious" },
                           { key: "flag_account", job: "FlagAccountJob",
                             branch_key: "fraud_check", branch_arm: "suspicious" },
                           # Second branch: shipping — pickup (empty arm)
                           { key: "shipping_method", job: branch_job, decides: "pick_shipping",
                             branch_result: "pickup", empty_arms: %w[pickup] },
                           { key: "schedule_courier", job: "ScheduleCourierJob",
                             branch_key: "shipping_method", branch_arm: "express",
                             status: "skipped_by_branch" },
                           { key: "generate_label", job: "GenerateLabelJob",
                             branch_key: "shipping_method", branch_arm: "express",
                             status: "skipped_by_branch" },
                           { key: "notify_warehouse", job: "NotifyWarehouseJob",
                             branch_key: "shipping_method", branch_arm: "standard",
                             status: "skipped_by_branch" },
                           { key: "send_confirmation", job: "SendConfirmationJob" })
add_edges(routing2, routing2_steps,
          %w[receive_order fraud_check],
          %w[fraud_check manual_review], %w[manual_review flag_account],
          %w[flag_account shipping_method],
          %w[shipping_method schedule_courier], %w[shipping_method notify_warehouse],
          %w[schedule_courier generate_label],
          %w[generate_label send_confirmation], %w[notify_warehouse send_confirmation])

# 19. NotificationRoutingPipeline (succeeded, skip arm to End) — branch at the end with empty arm
notif_routing = create_pipeline(type: "NotificationRoutingPipeline", status: "succeeded",
                                 params: { user_id: 77_200, event: "purchase" },
                                 age: 5.minutes, duration: 3.minutes)
notif_routing_steps = add_steps(notif_routing,
                                { key: "load_preferences", job: "LoadPreferencesJob" },
                                { key: "notification_channel", job: branch_job, decides: "preferred_channel",
                                  branch_result: "none", empty_arms: %w[none] },
                                { key: "send_email", job: "SendEmailJob",
                                  branch_key: "notification_channel", branch_arm: "email",
                                  status: "skipped_by_branch" },
                                { key: "send_push", job: "SendPushJob",
                                  branch_key: "notification_channel", branch_arm: "push",
                                  status: "skipped_by_branch" })
add_edges(notif_routing, notif_routing_steps,
          %w[load_preferences notification_channel],
          %w[notification_channel send_email], %w[notification_channel send_push])

# Fixture A: 139 steps and 224 edges. This independently exercises the
# dashboard's large-pipeline threshold without exceeding Mermaid's edge cap.
warehouse = create_pipeline(
  type: "DataWarehouseRebuildPipeline",
  status: "running",
  params: { warehouse: "analytics", shards: 48 },
  strategy: "continue",
  age: 2.hours
)
warehouse_defs = [
  { key: "plan", job: "WarehousePlanJob", start_after: 10, duration: 20 }
]

48.times do |index|
  suffix = index.to_s.rjust(2, "0")
  warehouse_defs << {
    key: "extract_#{suffix}", job: "WarehouseExtractJob",
    start_after: 35 + ((index % 8) * 2), duration: 20 + (index % 5)
  }
end

48.times do |index|
  suffix = index.to_s.rjust(2, "0")
  attributes = {
    key: "transform_#{suffix}", job: "WarehouseTransformJob",
    start_after: 90 + ((index % 8) * 3), duration: 30 + (index % 7)
  }
  if index < 36
    warehouse_defs << attributes
  elsif index < 39
    warehouse_defs << attributes.merge(status: "enqueued", job_state: :running)
  elsif index < 42
    warehouse_defs << attributes.merge(status: "enqueued", job_state: :queued)
  else
    warehouse_defs << attributes.merge(status: "pending", job_state: :none)
  end
end

warehouse_defs << {
  key: "merge", job: "WarehouseMergeJob", status: "pending", job_state: :none,
  start_after: 160, duration: 15
}
40.times do |index|
  warehouse_defs << {
    key: "load_#{index.to_s.rjust(2, '0')}", job: "WarehouseLoadJob",
    status: "pending", job_state: :none, start_after: 180 + index, duration: 10
  }
end
warehouse_defs << {
  key: "finalize", job: "WarehouseFinalizeJob", status: "pending", job_state: :none,
  start_after: 230, duration: 10
}

warehouse_steps = add_steps(warehouse, *warehouse_defs)
warehouse_edges = []
48.times do |index|
  suffix = index.to_s.rjust(2, "0")
  warehouse_edges << ["plan", "extract_#{suffix}"]
  warehouse_edges << ["extract_#{suffix}", "transform_#{suffix}"]
  warehouse_edges << ["transform_#{suffix}", "merge"]
end
40.times do |index|
  suffix = index.to_s.rjust(2, "0")
  warehouse_edges << ["merge", "load_#{suffix}"]
  warehouse_edges << ["load_#{suffix}", "finalize"]
end
add_edges(warehouse, warehouse_steps, *warehouse_edges)

# Fixture B: 46 nodes connected to every subsequent node, producing exactly
# C(46, 2) = 1,035 edges while remaining below the 60-step large-pipeline gate.
dense = create_pipeline(
  type: "DenseFanoutPipeline",
  status: "succeeded",
  params: { nodes: 46, topology: "fully_connected_forward" },
  strategy: "ignore",
  age: 26.hours,
  duration: 12.minutes
)
dense_defs = 46.times.map do |index|
  {
    key: "node_#{index.to_s.rjust(2, '0')}", job: "DenseFanoutNodeJob",
    start_after: 5 + (index * 10), duration: 5
  }
end
dense_steps = add_steps(dense, *dense_defs)
dense_edges = 46.times.flat_map do |from|
  ((from + 1)...46).map do |to|
    ["node_#{from.to_s.rjust(2, '0')}", "node_#{to.to_s.rjust(2, '0')}"]
  end
end
add_edges(dense, dense_steps, *dense_edges)

# A non-terminal execution is intentionally older than GoodJob's normal
# retention window. Its dangling IDs model job rows that cleanup has removed.
retention_gap = create_pipeline(
  type: "LongRunningArchivePipeline",
  status: "running",
  params: { archive: "legal-hold", partitions: 4 },
  strategy: "continue",
  age: 20.days
)
retention_steps = add_steps(
  retention_gap,
  { key: "scan", job: "ArchiveScanJob", job_state: :dangling },
  { key: "compact", job: "ArchiveCompactJob", job_state: :dangling },
  { key: "verify", job: "ArchiveVerifyJob", status: "enqueued", job_state: :dangling },
  { key: "publish", job: "ArchivePublishJob", status: "pending", job_state: :dangling }
)
add_edges(retention_gap, retention_steps, %w[scan compact], %w[compact verify], %w[verify publish])

# Add 180 compact historical executions. Together with the original 20 and the
# three scale/retention fixtures above, the dashboard has 203 rows to paginate.
# The generated set is exactly 80/8/5/4/3 percent (rounded) across statuses.
history_statuses = (["succeeded"] * 144) + (["running"] * 14) + (["failed"] * 9) +
                   (["halted"] * 7) + (["skipped"] * 6)
history_types = %w[
  CatalogRefreshPipeline CustomerImportPipeline DailyMetricsPipeline
  InventorySnapshotPipeline SearchReindexPipeline WebhookReplayPipeline
]

180.times do |index|
  status = history_statuses[(index * 73) % history_statuses.length]
  day_offset = index % 14
  slot = index / 14
  duration = status == "running" ? nil : (45 + ((index * 17) % 480)).seconds
  pipeline = create_pipeline(
    type: history_types[index % history_types.length],
    status: status,
    params: { run: index + 1, shard: index % 12, source: "demo" },
    strategy: %w[halt continue ignore][index % 3],
    created_at: recent_seed_time(day_offset, slot),
    duration: duration,
    halt_triggered: status == "halted"
  )

  step_defs = case status
              when "succeeded"
                [
                  { key: "prepare", job: "DemoPrepareJob", start_after: 5, duration: 8 },
                  { key: "process", job: "DemoProcessJob", start_after: 18, duration: 12 },
                  { key: "commit", job: "DemoCommitJob", start_after: 35, duration: 7 }
                ]
              when "running"
                active_state = index.even? ? :running : :queued
                [
                  { key: "prepare", job: "DemoPrepareJob", start_after: 5, duration: 8 },
                  { key: "process", job: "DemoProcessJob", status: "enqueued",
                    job_state: active_state, start_after: 18, duration: 12 },
                  { key: "commit", job: "DemoCommitJob", status: "pending", job_state: :none }
                ]
              when "failed"
                [
                  { key: "prepare", job: "DemoPrepareJob", start_after: 5, duration: 8 },
                  { key: "process", job: "DemoProcessJob", status: "failed", start_after: 18, duration: 12,
                    error_class: "DemoImportError", error_message: "Synthetic row #{index + 1} could not be imported" },
                  { key: "commit", job: "DemoCommitJob", status: "skipped", job_state: :none }
                ]
              when "halted"
                [
                  { key: "prepare", job: "DemoPrepareJob", status: "failed", start_after: 5, duration: 8,
                    error_class: "DemoHalt", error_message: "Synthetic safety check halted the execution" },
                  { key: "process", job: "DemoProcessJob", status: "halted", start_after: 18, duration: 4 },
                  { key: "commit", job: "DemoCommitJob", status: "skipped", job_state: :none }
                ]
              else
                [
                  { key: "prepare", job: "DemoPrepareJob", status: "skipped", job_state: :none },
                  { key: "process", job: "DemoProcessJob", status: "skipped", job_state: :none },
                  { key: "commit", job: "DemoCommitJob", status: "skipped", job_state: :none }
                ]
              end

  steps = add_steps(pipeline, *step_defs)
  add_edges(pipeline, steps, %w[prepare process], %w[process commit])
end

puts "Done! #{GoodPipeline::PipelineRecord.count} pipelines, " \
     "#{GoodPipeline::StepRecord.count} steps, and " \
     "#{GoodJob::Job.where(queue_name: SEED_JOB_QUEUE).count} synthetic jobs seeded."
