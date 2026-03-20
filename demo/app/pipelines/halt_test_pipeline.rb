# frozen_string_literal: true

class HaltTestPipeline < GoodPipeline::Pipeline
  failure_strategy :halt

  def configure(**_kwargs)
    run :step_a, FailingJob
    run :step_b, DownloadJob, after: :step_a
  end
end
