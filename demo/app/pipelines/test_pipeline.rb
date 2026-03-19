# frozen_string_literal: true

class TestPipeline < GoodPipeline::Pipeline
  def configure(**) = run(:default, DownloadJob)
end
