# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module GoodPipeline
  class InstallGenerator < Rails::Generators::Base
    include ActiveRecord::Generators::Migration

    source_root File.expand_path("templates", __dir__)

    desc "Creates the GoodPipeline migration file."
    def create_migration_file
      migration_template(
        "create_good_pipeline_tables.rb.erb",
        "db/migrate/create_good_pipeline_tables.rb"
      )
    end
  end
end
