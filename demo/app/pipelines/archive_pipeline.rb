# frozen_string_literal: true

class ArchivePipeline < GoodPipeline::Pipeline
  def configure(**_kwargs)
    run :archive, DownloadJob
  end
end
