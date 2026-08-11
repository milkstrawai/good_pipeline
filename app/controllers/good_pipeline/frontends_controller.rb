# frozen_string_literal: true

module GoodPipeline
  class FrontendsController < ApplicationController
    # Rails' same-origin JavaScript response check treats an engine asset served
    # through a controller like an executable action response. These files are
    # public, versioned static assets and never read or mutate session state.
    skip_forgery_protection only: :static

    def static
      file_name = "#{sanitized_id}.#{sanitized_format}"
      file_path = assets_directory.join(file_name)

      if file_path.exist?
        apply_cache_headers
        send_file file_path, disposition: :inline
      else
        head :not_found
      end
    end

    private

    # The asset URL embeds GoodPipeline::VERSION, so a released build is immutable
    # and safe to cache for a year. In development that version does not change
    # between edits, which would otherwise pin the browser to a stale stylesheet
    # for the life of the release.
    def apply_cache_headers
      if Rails.env.development?
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
      else
        expires_in 1.year, public: true
      end
    end

    def sanitized_id
      params[:id].to_s.gsub(/[^a-zA-Z0-9_-]/, "")
    end

    def sanitized_format
      params[:format].to_s.gsub(/[^a-zA-Z0-9]/, "")
    end

    def assets_directory
      GoodPipeline::Engine.root.join("app", "frontend", "good_pipeline")
    end
  end
end
