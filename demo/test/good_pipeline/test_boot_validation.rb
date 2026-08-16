# frozen_string_literal: true

require "test_helper"
require "open3"

# Real-boot regression for initializer ordering: GoodJob applies
# `config.good_job.*` in an after_initialize callback registered by its
# `good_job.rails_config` initializer. GoodPipeline's validation must run
# after that — validating at on_load(:active_job) read GoodJob's defaults, so
# an application configuring preserve_job_records = false booted broken.
# Only a subprocess boot exercises the actual initializer graph.
class TestBootValidation < ActiveSupport::TestCase
  DEMO_ROOT = File.expand_path("../..", __dir__)

  def test_boot_fails_when_rails_config_disables_preserve_job_records
    stdout, stderr, status = run_demo_runner(extra_env: { "GP_BREAK_PRESERVE_JOB_RECORDS" => "1" })

    refute_predicate status, :success?, "boot should fail (stdout: #{stdout})"
    assert_match(/GoodPipeline requires GoodJob.preserve_job_records = true/, stderr + stdout)
  end

  # Rails 7.2 load defaults make ActiveJob::Base consult the adapter, while
  # Rails 8.0+ class settings remain false and do not consult GoodJob's raw
  # adapter option. This subprocess proves both the version semantics and that
  # GoodJob's Rails configuration was applied before GoodPipeline validates it.
  def test_boot_validates_effective_enqueue_deferral_for_the_active_job_version
    stdout, stderr, status = run_demo_runner(extra_env: { "GP_ENABLE_ADAPTER_ENQUEUE_DEFERRAL" => "1" })

    if ActiveJob.gem_version < Gem::Version.new("8.0")
      refute_predicate status, :success?, "Rails 7.2 boot should fail (stdout: #{stdout})"
      assert_match(/effectively defers enqueue/, stderr + stdout)
    else
      assert_predicate status, :success?, "Rails 8.0+ boot should succeed (stderr: #{stderr})"
      assert_includes stdout, "BOOTED_OK"
    end
  end

  def test_boot_rejects_effective_async_without_positive_polling_even_with_listen_notify
    stdout, stderr, status = run_demo_runner(extra_env: { "GP_BREAK_ASYNC_POLLING" => "1" })

    refute_predicate status, :success?, "boot should fail (stdout: #{stdout})"
    assert_match(/poll_interval > 0/, stderr + stdout)
    assert_match(%r{LISTEN/NOTIFY alone cannot recover}, stderr + stdout)
  end

  def test_boot_succeeds_with_valid_configuration
    stdout, _stderr, status = run_demo_runner

    assert_predicate status, :success?
    assert_includes stdout, "BOOTED_OK"
  end

  private

  def run_demo_runner(extra_env: {})
    env = { "RAILS_ENV" => "test" }.merge(extra_env)
    Open3.capture3(env, "bin/rails", "runner", "puts 'BOOTED_OK'", chdir: DEMO_ROOT)
  end
end
