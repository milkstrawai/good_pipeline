# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module GoodPipeline
  class UpgradeGenerator < Rails::Generators::Base
    include ActiveRecord::Generators::Migration

    source_root File.expand_path("templates", __dir__)

    desc "Creates migrations needed when upgrading GoodPipeline."
    def create_dashboard_indexes_migration
      if dashboard_indexes_migration_exists?
        say_status :skip, "dashboard indexes migration already exists"
        return
      end

      migration_template(
        "add_good_pipeline_dashboard_indexes.rb.erb",
        "db/migrate/add_good_pipeline_dashboard_indexes.rb"
      )
    end

    private

    def dashboard_indexes_migration_exists?
      pattern = File.join(destination_root, "db/migrate/*_add_good_pipeline_dashboard_indexes.rb")
      Dir.glob(pattern).any?
    end
  end
end
