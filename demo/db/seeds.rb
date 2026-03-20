# frozen_string_literal: true

puts "Seeding GoodPipeline demo data..."

GoodPipeline::ChainRecord.delete_all
GoodPipeline::DependencyRecord.delete_all
GoodPipeline::StepRecord.delete_all
GoodPipeline::PipelineRecord.delete_all

NOW = Time.current # rubocop:disable Lint/ConstantDefinitionInBlock

def create_pipeline(type:, status:, params:, strategy: "halt", age:, duration: nil, halt_triggered: false) # rubocop:disable Metrics/ParameterLists
  pipeline = GoodPipeline::PipelineRecord.create!(
    type: type, status: status, params: params,
    on_failure_strategy: strategy, halt_triggered: halt_triggered
  )
  pipeline.update_columns(
    created_at: NOW - age,
    updated_at: duration ? NOW - age + duration : NOW - age
  )
  pipeline
end

def add_steps(pipeline, *step_defs)
  records = {}
  step_defs.each do |definition|
    records[definition[:key]] = GoodPipeline::StepRecord.create!(
      pipeline: pipeline, key: definition[:key], job_class: definition[:job],
      coordination_status: definition.fetch(:status, "succeeded"),
      error_class: definition[:error_class], error_message: definition[:error_message]
    )
  end
  records
end

def add_edges(pipeline, steps, *edges)
  edges.each do |from, to|
    GoodPipeline::DependencyRecord.create!(pipeline: pipeline, step: steps[to], depends_on_step: steps[from])
  end
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
                         { key: "aggregate", job: "AggregateJob", status: "enqueued" },
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
                          { key: "validate", job: "ValidateJob", status: "enqueued" },
                          { key: "transform", job: "TransformJob", status: "pending" },
                          { key: "load", job: "LoadJob", status: "pending" })
add_edges(ingest2, ingest2_steps, %w[extract validate], %w[validate transform], %w[transform load])

puts "Done! #{GoodPipeline::PipelineRecord.count} pipelines seeded."
