# frozen_string_literal: true

module GoodPipeline
  class FrontendsController < ApplicationController
    def static
      file_name = "#{sanitized_id}.#{sanitized_format}"
      file_path = assets_directory.join(file_name)

      if file_path.exist?
        expires_in 1.year, public: true
        send_file file_path, disposition: :inline
      else
        head :not_found
      end
    end

    private

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
