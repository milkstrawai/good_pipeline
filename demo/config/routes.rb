# frozen_string_literal: true

Rails.application.routes.draw do
  mount GoodJob::Engine => "/good_job"
  mount GoodPipeline::Engine => "/good_pipeline"
end
