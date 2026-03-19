# frozen_string_literal: true

class VideoProcessingPipeline < GoodPipeline::Pipeline
  description "Downloads, transcodes and publishes a video"
  failure_strategy :halt

  def configure(video_id:, **)
    run :download, DownloadJob, with: { video_id: video_id }
    run :transcode, TranscodeJob, after: :download
    run :thumbnail, ThumbnailJob, after: :download
    run :publish, PublishJob, after: %i[transcode thumbnail]
    run :cleanup, CleanupJob, after: :publish
  end
end
