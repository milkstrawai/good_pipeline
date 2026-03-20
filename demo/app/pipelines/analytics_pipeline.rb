# frozen_string_literal: true

class AnalyticsPipeline < GoodPipeline::Pipeline
  def configure(**_kwargs)
    run :analyze, DownloadJob
  end
end
