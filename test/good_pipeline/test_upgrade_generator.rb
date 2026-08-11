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

  def test_install_template_contains_nonconcurrent_dashboard_indexes
    template = File.read(
      File.expand_path(
        "../../lib/generators/good_pipeline/install/templates/create_good_pipeline_tables.rb.erb",
        __dir__
      )
    )

    assert_includes template, "ActiveRecord::Migration.current_version"
    assert_includes template, "index_gp_pipelines_on_status_created_at_id"
    refute_includes template, "algorithm: :concurrently"
  end

  private

  def run_generator
    generator = GoodPipeline::UpgradeGenerator.new([], {}, destination_root: @destination)
    capture_io { generator.invoke_all }
  end

  def generated_migrations
    Dir[File.join(@destination, "db/migrate/*_add_good_pipeline_dashboard_indexes.rb")]
  end
end
