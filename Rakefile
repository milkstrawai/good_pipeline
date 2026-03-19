# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rubocop/rake_task"

Minitest::TestTask.create(:test_unit) do |task|
  task.test_globs = ["test/**/*test*.rb"]
end

desc "Run integration tests"
task :test_integration do
  sh "ruby -Idemo/test -e 'Dir[\"demo/test/**/*test*.rb\"].sort.each { |file| require File.expand_path(file) }'"
end

task test: %i[test_unit test_integration]

RuboCop::RakeTask.new

task default: %i[test rubocop]
