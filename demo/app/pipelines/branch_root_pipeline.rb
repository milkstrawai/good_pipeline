# frozen_string_literal: true

# A branch as the pipeline's own root. Branch roots take the single-step enqueue
# path rather than the bulk one (resolve_step has to evaluate the decision), and
# `branch` emits a branch's arm steps before the branch step itself — so this is
# the shape that exposes lock ordering between cancel and root enqueue.
class BranchRootPipeline < GoodPipeline::Pipeline
  description "Pipeline whose root is a branch, for cancel/enqueue lock-order coverage"

  def configure(choice:, **)
    branch :pick, by: :pick_arm do
      on :go do
        run :work, DownloadJob, with: { choice: choice }
      end

      on :stop do
        run :other, PublishJob, with: { choice: choice }
      end
    end

    run :finish, CleanupJob, with: { choice: choice }, after: :pick
  end

  private

  def pick_arm
    params[:choice].to_sym
  end
end
