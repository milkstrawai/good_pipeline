# frozen_string_literal: true

class BranchTestPipeline < GoodPipeline::Pipeline
  description "Pipeline with branching for integration tests"

  def configure(choice:, **)
    run :analyze, DownloadJob, with: { choice: choice }

    branch :format_check, after: :analyze, by: :pick_format do
      on :hd do
        run :transcode_hd, TranscodeJob, with: { choice: choice }
        run :upscale, ThumbnailJob, with: { choice: choice }, after: :transcode_hd
      end

      on :sd do
        run :transcode_sd, PublishJob, with: { choice: choice }
      end
    end

    run :finish, CleanupJob, with: { choice: choice }, after: :format_check
  end

  private

  def pick_format
    params[:choice].to_sym
  end
end
