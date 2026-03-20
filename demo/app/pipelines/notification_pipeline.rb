# frozen_string_literal: true

class NotificationPipeline < GoodPipeline::Pipeline
  def configure(**_kwargs)
    run :notify, DownloadJob
  end
end
