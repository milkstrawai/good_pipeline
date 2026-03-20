# frozen_string_literal: true

puts "Seeding GoodPipeline demo data..."

GoodPipeline::ChainRecord.delete_all
GoodPipeline::DependencyRecord.delete_all
GoodPipeline::StepRecord.delete_all
GoodPipeline::PipelineRecord.delete_all

# --- 1. VideoProcessingPipeline (succeeded) ---
video_pipeline = GoodPipeline::PipelineRecord.create!(
  type: "VideoProcessingPipeline", status: "succeeded",
  params: { video_id: 42 }, on_failure_strategy: "halt"
)

download = GoodPipeline::StepRecord.create!(
  pipeline: video_pipeline, key: "download", job_class: "DownloadJob", coordination_status: "succeeded"
)
transcode = GoodPipeline::StepRecord.create!(
  pipeline: video_pipeline, key: "transcode", job_class: "TranscodeJob", coordination_status: "succeeded"
)
thumbnail = GoodPipeline::StepRecord.create!(
  pipeline: video_pipeline, key: "thumbnail", job_class: "ThumbnailJob", coordination_status: "succeeded"
)
publish = GoodPipeline::StepRecord.create!(
  pipeline: video_pipeline, key: "publish", job_class: "PublishJob", coordination_status: "succeeded"
)
cleanup = GoodPipeline::StepRecord.create!(
  pipeline: video_pipeline, key: "cleanup", job_class: "CleanupJob", coordination_status: "succeeded"
)

GoodPipeline::DependencyRecord.create!(pipeline: video_pipeline, step: transcode, depends_on_step: download)
GoodPipeline::DependencyRecord.create!(pipeline: video_pipeline, step: thumbnail, depends_on_step: download)
GoodPipeline::DependencyRecord.create!(pipeline: video_pipeline, step: publish, depends_on_step: transcode)
GoodPipeline::DependencyRecord.create!(pipeline: video_pipeline, step: publish, depends_on_step: thumbnail)
GoodPipeline::DependencyRecord.create!(pipeline: video_pipeline, step: cleanup, depends_on_step: publish)
puts "  Created VideoProcessingPipeline (succeeded)"

# --- 2. HaltTestPipeline (halted) ---
halted_pipeline = GoodPipeline::PipelineRecord.create!(
  type: "HaltTestPipeline", status: "halted",
  params: {}, on_failure_strategy: "halt"
)

failed_step = GoodPipeline::StepRecord.create!(
  pipeline: halted_pipeline, key: "step_a", job_class: "FailingJob", coordination_status: "failed",
  error_class: "RuntimeError", error_message: "Something went wrong"
)
skipped_step = GoodPipeline::StepRecord.create!(
  pipeline: halted_pipeline, key: "step_b", job_class: "DownloadJob", coordination_status: "skipped"
)

GoodPipeline::DependencyRecord.create!(pipeline: halted_pipeline, step: skipped_step, depends_on_step: failed_step)
puts "  Created HaltTestPipeline (halted)"

# --- 3. ContinueTestPipeline (failed) ---
continue_pipeline = GoodPipeline::PipelineRecord.create!(
  type: "ContinueTestPipeline", status: "failed",
  params: {}, on_failure_strategy: "continue"
)

continue_step_a = GoodPipeline::StepRecord.create!(
  pipeline: continue_pipeline, key: "step_a", job_class: "FailingJob", coordination_status: "failed",
  error_class: "RuntimeError", error_message: "Intentional failure"
)
continue_step_b = GoodPipeline::StepRecord.create!(
  pipeline: continue_pipeline, key: "step_b", job_class: "DownloadJob", coordination_status: "succeeded"
)
continue_step_c = GoodPipeline::StepRecord.create!(
  pipeline: continue_pipeline, key: "step_c", job_class: "DownloadJob", coordination_status: "skipped"
)

GoodPipeline::DependencyRecord.create!(pipeline: continue_pipeline, step: continue_step_c, depends_on_step: continue_step_a)
GoodPipeline::DependencyRecord.create!(pipeline: continue_pipeline, step: continue_step_c, depends_on_step: continue_step_b)
puts "  Created ContinueTestPipeline (failed)"

# --- 4. Chain: TestPipeline -> NotificationPipeline (both succeeded) ---
chain_upstream = GoodPipeline::PipelineRecord.create!(
  type: "TestPipeline", status: "succeeded",
  params: {}, on_failure_strategy: "halt"
)
GoodPipeline::StepRecord.create!(
  pipeline: chain_upstream, key: "default", job_class: "DownloadJob", coordination_status: "succeeded"
)

chain_downstream = GoodPipeline::PipelineRecord.create!(
  type: "NotificationPipeline", status: "succeeded",
  params: {}, on_failure_strategy: "halt"
)
GoodPipeline::StepRecord.create!(
  pipeline: chain_downstream, key: "notify", job_class: "DownloadJob", coordination_status: "succeeded"
)

GoodPipeline::ChainRecord.create!(upstream_pipeline: chain_upstream, downstream_pipeline: chain_downstream)
puts "  Created TestPipeline -> NotificationPipeline chain (both succeeded)"

# --- 5. Chain: HaltTestPipeline -> ArchivePipeline (halted -> skipped) ---
chain_halted = GoodPipeline::PipelineRecord.create!(
  type: "HaltTestPipeline", status: "halted",
  params: {}, on_failure_strategy: "halt"
)
halted_step_a = GoodPipeline::StepRecord.create!(
  pipeline: chain_halted, key: "step_a", job_class: "FailingJob", coordination_status: "failed",
  error_class: "RuntimeError", error_message: "Boom"
)
halted_step_b = GoodPipeline::StepRecord.create!(
  pipeline: chain_halted, key: "step_b", job_class: "DownloadJob", coordination_status: "skipped"
)
GoodPipeline::DependencyRecord.create!(pipeline: chain_halted, step: halted_step_b, depends_on_step: halted_step_a)

chain_skipped = GoodPipeline::PipelineRecord.create!(
  type: "ArchivePipeline", status: "skipped",
  params: {}, on_failure_strategy: "halt"
)
GoodPipeline::StepRecord.create!(
  pipeline: chain_skipped, key: "archive", job_class: "DownloadJob", coordination_status: "skipped"
)

GoodPipeline::ChainRecord.create!(upstream_pipeline: chain_halted, downstream_pipeline: chain_skipped)
puts "  Created HaltTestPipeline -> ArchivePipeline chain (halted -> skipped)"

# --- 6. VideoProcessingPipeline (running) ---
running_pipeline = GoodPipeline::PipelineRecord.create!(
  type: "VideoProcessingPipeline", status: "running",
  params: { video_id: 99 }, on_failure_strategy: "halt"
)

running_download = GoodPipeline::StepRecord.create!(
  pipeline: running_pipeline, key: "download", job_class: "DownloadJob", coordination_status: "succeeded"
)
running_transcode = GoodPipeline::StepRecord.create!(
  pipeline: running_pipeline, key: "transcode", job_class: "TranscodeJob", coordination_status: "enqueued"
)
running_thumbnail = GoodPipeline::StepRecord.create!(
  pipeline: running_pipeline, key: "thumbnail", job_class: "ThumbnailJob", coordination_status: "enqueued"
)
GoodPipeline::StepRecord.create!(
  pipeline: running_pipeline, key: "publish", job_class: "PublishJob", coordination_status: "pending"
)
GoodPipeline::StepRecord.create!(
  pipeline: running_pipeline, key: "cleanup", job_class: "CleanupJob", coordination_status: "pending"
)

GoodPipeline::DependencyRecord.create!(pipeline: running_pipeline, step: running_transcode, depends_on_step: running_download)
GoodPipeline::DependencyRecord.create!(pipeline: running_pipeline, step: running_thumbnail, depends_on_step: running_download)
# publish depends on transcode + thumbnail (need references)
running_publish = GoodPipeline::StepRecord.find_by(pipeline: running_pipeline, key: "publish")
running_cleanup = GoodPipeline::StepRecord.find_by(pipeline: running_pipeline, key: "cleanup")
GoodPipeline::DependencyRecord.create!(pipeline: running_pipeline, step: running_publish, depends_on_step: running_transcode)
GoodPipeline::DependencyRecord.create!(pipeline: running_pipeline, step: running_publish, depends_on_step: running_thumbnail)
GoodPipeline::DependencyRecord.create!(pipeline: running_pipeline, step: running_cleanup, depends_on_step: running_publish)
puts "  Created VideoProcessingPipeline (running)"

puts "Done! #{GoodPipeline::PipelineRecord.count} pipelines seeded."
