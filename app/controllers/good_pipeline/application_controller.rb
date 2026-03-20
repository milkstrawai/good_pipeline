# frozen_string_literal: true

module GoodPipeline
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    layout "good_pipeline/application"
  end
end
