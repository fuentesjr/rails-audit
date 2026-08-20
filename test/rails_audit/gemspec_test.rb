# frozen_string_literal: true

require "test_helper"

class GemspecTest < Minitest::Test
  def setup
    gemspec_path = File.expand_path("../../rails-audit.gemspec", __dir__)
    @spec = Gem::Specification.load(gemspec_path)
  end

  def test_packages_required_runtime_and_docs_files
    files = @spec.files
    %w[
      lib/rails_audit.rb
      exe/rails-audit
      config/rails_audit/rubocop.yml
      Gemfile
      Gemfile.lock
      LICENSE.txt
      README.md
      CHANGELOG.md
      SECURITY.md
      CODE_OF_CONDUCT.md
      rails-audit.gemspec
    ].each do |path|
      assert_includes files, path, "expected packaged files to include #{path}"
    end
  end

  def test_excludes_tracker_docs_and_internal_files
    files = @spec.files
    refute_includes files, "AGENTS.md"
    refute_includes files, "CLAUDE.md"
    refute_includes files, "PROJECT_TRACKER.md"
    refute_includes files, "CONTRIBUTING.md"
    refute_includes files, "FAQ.md"
    refute_includes files, "Rakefile"
    refute(files.any? { |path| path.start_with?(".trk/") }, "expected no .trk/ paths")
    refute(files.any? { |path| path.start_with?("docs/") }, "expected no docs/ paths")
  end

  def test_exposes_rails_audit_executable
    assert_includes @spec.executables, "rails-audit"
  end

  def test_requires_rubygems_mfa
    assert_equal "true", @spec.metadata["rubygems_mfa_required"]
  end

  def test_uses_duck_email
    assert_includes @spec.email, "fuentesjr@duck.com"
  end
end
