# frozen_string_literal: true

require_relative "lib/good_pipeline/version"

Gem::Specification.new do |spec|
  spec.name = "good_pipeline"
  spec.version = GoodPipeline::VERSION
  spec.authors = ["Ali Hamdi Ali Fadel"]
  spec.email = ["aliosm1997@gmail.com"]

  spec.summary = "DAG-based job pipeline orchestration for Rails, built on GoodJob"
  spec.description = "Define multi-step workflows as directed acyclic graphs " \
                     "where each step is a GoodJob job. Handles dependency " \
                     "resolution, parallel execution, failure strategies, " \
                     "and lifecycle callbacks."
  spec.homepage = "https://github.com/milkstrawai/good_pipeline"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/milkstrawai/good_pipeline"
  spec.metadata["changelog_uri"] = "https://github.com/milkstrawai/good_pipeline/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "good_job", ">= 3.10"
  spec.add_dependency "railties", ">= 7.1"
end
