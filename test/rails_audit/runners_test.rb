# frozen_string_literal: true

require "test_helper"

class RunnersTest < Minitest::Test
  def test_gem_version_reads_resolved_specs_from_gemfile_lock
    version = RailsAudit::Runners.send(:gem_version, "brakeman")

    assert_match(/\A\d+\.\d+\.\d+\z/, version)
  end

  def test_gem_version_tolerates_crlf_line_endings
    lockfile = <<~LOCK.gsub("\n", "\r\n")
      GEM
        remote: https://rubygems.org/
        specs:
          brakeman (8.0.5)
          reek (6.5.0)
    LOCK
    real_read = File.method(:read)

    version = File.stub(
      :read,
      lambda { |path, *args|
        if path == RailsAudit::Runners::GEMFILE_LOCK
          lockfile
        else
          real_read.call(path, *args)
        end
      }
    ) do
      RailsAudit::Runners.send(:gem_version, "brakeman")
    end

    assert_equal "8.0.5", version
  end

  def test_gem_version_raises_when_tool_is_missing_from_lockfile
    lockfile = "GEM\n  specs:\n    reek (6.5.0)\n"
    real_read = File.method(:read)

    error = assert_raises(RailsAudit::Error) do
      File.stub(
        :read,
        lambda { |path, *args|
          if path == RailsAudit::Runners::GEMFILE_LOCK
            lockfile
          else
            real_read.call(path, *args)
          end
        }
      ) do
        RailsAudit::Runners.send(:gem_version, "brakeman")
      end
    end

    assert_includes error.message, "brakeman is missing from Gemfile.lock"
  end
end
