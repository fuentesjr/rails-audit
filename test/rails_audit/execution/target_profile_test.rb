# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"

class TargetProfileTest < Minitest::Test
  def test_resolves_ruby_from_gemfile_and_postgres_adapter
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        ruby "3.4.5"
        gem "rails", "~> 7.2"
        gem "pg"
      RUBY
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "database.yml"), "adapter: postgresql\n")

      profile = RailsAudit::Execution::TargetProfile.from_path(dir)

      assert_equal "3.4.5", profile.ruby_image_version
      assert_equal "3.4.5", profile.ruby_version
      assert_equal :postgresql, profile.adapter
      refute profile.redis?
    end
  end

  def test_ruby_version_file_takes_precedence_and_mysql_is_structured
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".ruby-version"), "ruby-3.3.7\n")
      File.write(File.join(dir, "Gemfile"), "ruby \"3.4.5\"\ngem \"mysql2\"\n")

      profile = RailsAudit::Execution::TargetProfile.from_path(dir)

      assert_equal "3.3.7", profile.ruby_version
      assert_equal :mysql, profile.adapter
    end
  end
end
