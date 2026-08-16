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
