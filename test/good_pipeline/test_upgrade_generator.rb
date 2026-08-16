# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "generators/good_pipeline/upgrade/upgrade_generator"

class TestUpgradeGenerator < Minitest::Test
  def setup
    @destination = Dir.mktmpdir("good-pipeline-upgrade")
  end

  def teardown
    FileUtils.rm_rf(@destination)
  end

  def test_generator_emits_current_version_and_concurrent_rerunnable_indexes
    run_generator
    content = File.read(generated_migrations.fetch(0))

    assert_includes content, "ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]"
    assert_includes content, "disable_ddl_transaction!"
    assert_equal 3, content.scan("algorithm: :concurrently, if_not_exists: true").length
    assert_includes content, "index_gp_pipelines_on_type_created_at_id"
    assert_includes content, "WHERE NOT i.indisvalid"
  end

  def test_second_generator_run_is_a_no_op
    run_generator
    first_path = generated_migrations.fetch(0)
    first_content = File.read(first_path)

    run_generator

    assert_equal [first_path], generated_migrations
    assert_equal first_content, File.read(first_path)
  end

  def test_generator_emits_a_rerunnable_cancellation_migration
    run_generator
    content = File.read(generated_cancellation_migrations.fetch(0))

    assert_includes content, "ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]"
    assert_includes content, "add_column :good_pipeline_pipelines, :canceled_at, :datetime, if_not_exists: true"
  end

  def test_second_generator_run_does_not_duplicate_the_cancellation_migration
    run_generator
    first_path = generated_cancellation_migrations.fetch(0)

    run_generator

    assert_equal [first_path], generated_cancellation_migrations
  end

  # A v0.4 app already has the dashboard-indexes migration but not the
  # cancellation one; the generator must skip the former and emit the latter.
  def test_partial_upgrade_emits_only_the_missing_cancellation_migration
    run_generator
    dashboard_path = generated_migrations.fetch(0)
    File.delete(generated_cancellation_migrations.fetch(0))

    run_generator

    assert_equal [dashboard_path], generated_migrations
    assert_equal 1, generated_cancellation_migrations.length
  end

  def test_install_template_creates_the_cancellation_column_up_front
    assert_includes install_template, "t.datetime :canceled_at"
  end

  def test_install_template_contains_nonconcurrent_dashboard_indexes
    template = install_template

    assert_includes template, "ActiveRecord::Migration.current_version"
    assert_includes template, "index_gp_pipelines_on_status_created_at_id"
    refute_includes template, "algorithm: :concurrently"
  end

  private

  def install_template
    File.read(
      File.expand_path(
        "../../lib/generators/good_pipeline/install/templates/create_good_pipeline_tables.rb.erb",
        __dir__
      )
    )
  end

  def generated_cancellation_migrations
    Dir[File.join(@destination, "db/migrate/*_add_good_pipeline_cancellation.rb")]
  end

  def run_generator
    generator = GoodPipeline::UpgradeGenerator.new([], {}, destination_root: @destination)
    capture_io { generator.invoke_all }
  end

  def generated_migrations
    Dir[File.join(@destination, "db/migrate/*_add_good_pipeline_dashboard_indexes.rb")]
  end
end
