# frozen_string_literal: true

require_relative "lib/rails_audit/version"

Gem::Specification.new do |spec|
  spec.name = "rails-audit"
  spec.version = RailsAudit::VERSION
  spec.authors = ["Salvador Fuentes Jr."]
  spec.email = ["9240+fuentesjr@users.noreply.github.com"]

  spec.summary = "Deterministic Rails audit CLI"
  spec.description = "Runs a pinned toolchain of static-analysis tools (brakeman, " \
                     "rubocop + extensions, reek) against a Rails codebase, normalizes " \
                     "their output into one findings schema, and renders a " \
                     "severity-ranked report. See docs/DESIGN.md."
  spec.homepage = "https://github.com/fuentesjr/rails-audit"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/fuentesjr/rails-audit"
  spec.metadata["changelog_uri"] = "https://github.com/fuentesjr/rails-audit/blob/main/CHANGELOG.md"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/])
    end
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

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
