# frozen_string_literal: true

module GoodPipeline
  class ThemesController < ApplicationController
    THEMES = %w[dark light].freeze

    def update
      theme = params[:theme].to_s
      return head :unprocessable_entity unless THEMES.include?(theme)

      cookies.permanent[:good_pipeline_theme] = { value: theme, same_site: :lax }
      head :no_content
    end
  end
end
