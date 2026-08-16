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

    def create_cancellation_migration
      if cancellation_migration_exists?
        say_status :skip, "cancellation migration already exists"
        return
      end

      migration_template(
        "add_good_pipeline_cancellation.rb.erb",
        "db/migrate/add_good_pipeline_cancellation.rb"
      )
    end

    private

    def dashboard_indexes_migration_exists?
      migration_exists?("add_good_pipeline_dashboard_indexes")
    end

    def cancellation_migration_exists?
      migration_exists?("add_good_pipeline_cancellation")
    end

    def migration_exists?(basename)
      Dir.glob(File.join(destination_root, "db/migrate/*_#{basename}.rb")).any?
    end
  end
end
