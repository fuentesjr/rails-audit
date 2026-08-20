# frozen_string_literal: true

require_relative "lib/rails_audit/version"

Gem::Specification.new do |spec|
  spec.name = "rails-audit"
  spec.version = RailsAudit::VERSION
  spec.authors = ["Salvador Fuentes Jr."]
  spec.email = ["fuentesjr@duck.com"]

  spec.summary = "Deterministic Rails audit CLI"
  spec.description = "Runs a pinned toolchain of static-analysis tools (brakeman, " \
                     "rubocop + extensions, reek) against a Rails codebase, normalizes " \
                     "their output into one findings schema, and renders a " \
                     "severity-ranked report."
  spec.homepage = "https://github.com/fuentesjr/rails-audit"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/fuentesjr/rails-audit"
  spec.metadata["changelog_uri"] = "https://github.com/fuentesjr/rails-audit/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/fuentesjr/rails-audit/issues"
  spec.metadata["documentation_uri"] = "https://github.com/fuentesjr/rails-audit/blob/main/README.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  gem_root = __dir__
  spec.files = Dir.glob("lib/**/*", File::FNM_DOTMATCH, base: gem_root)
                  .reject { |f| File.directory?(File.join(gem_root, f)) } +
               Dir.glob("exe/rails-audit", base: gem_root)
                  .select { |f| File.file?(File.join(gem_root, f)) } +
               Dir.glob("config/rails_audit/**/*", File::FNM_DOTMATCH, base: gem_root)
                  .reject { |f| File.directory?(File.join(gem_root, f)) } +
               %w[Gemfile Gemfile.lock LICENSE.txt README.md CHANGELOG.md SECURITY.md CODE_OF_CONDUCT.md rails-audit.gemspec]
                 .select { |f| File.exist?(File.join(gem_root, f)) }
  unless spec.files.include?("lib/rails_audit.rb")
    raise "rails-audit.gemspec: lib/rails_audit.rb missing from packaged files; " \
          "build from the repo root (gem build rails-audit.gemspec)."
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Pinned analysis toolchain. Versions are exact, not pessimistic: the
  # determinism contract (docs/DESIGN.md §4) scopes the exit-code, impact, and
  # category tables to these exact versions. Bumping any tool requires
  # re-verifying its exit-code table and re-checking for schema drift first.
  spec.add_dependency "brakeman", "8.0.5"
  spec.add_dependency "reek", "6.5.0"
  spec.add_dependency "rubocop", "1.88.2"
  spec.add_dependency "rubocop-minitest", "0.40.0"
  spec.add_dependency "rubocop-performance", "1.26.1"
  spec.add_dependency "rubocop-rails", "2.35.5"
end
