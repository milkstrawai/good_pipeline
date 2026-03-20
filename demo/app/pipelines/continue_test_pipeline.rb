# frozen_string_literal: true

class ContinueTestPipeline < GoodPipeline::Pipeline
  failure_strategy :continue

  def configure(**_kwargs)
    run :step_a, FailingJob
    run :step_b, DownloadJob
    run :step_c, DownloadJob, after: %i[step_a step_b]
  end
end
