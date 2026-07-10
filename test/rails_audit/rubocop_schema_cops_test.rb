# frozen_string_literal: true

require "json"
require "tmpdir"
require "test_helper"

class RubocopSchemaCopsTest < Minitest::Test
  TARGET = File.expand_path("../fixtures/schema_app", __dir__)
  EXPECTED_COPS = %w[
    Rails/AddColumnIndex
    Rails/DangerousColumnNames
    Rails/MigrationClassName
    Rails/NotNullColumn
    Rails/ReversibleMigration
    Rails/ThreeStateBooleanColumn
    Rails/UniqueValidationWithoutIndex
  ].freeze

  def test_real_runner_loads_static_schema_and_migration_cops
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "rubocop.json")

      with_environment("XDG_CACHE_HOME" => File.join(dir, "cache")) do
        RailsAudit::Runners.rubocop(target: TARGET, output_path: output_path)
      end

      raw = JSON.parse(File.read(output_path))
      offenses = raw.fetch("files").flat_map { |file| file.fetch("offenses") }
      cop_names = offenses.map { |offense| offense.fetch("cop_name") }

      EXPECTED_COPS.each do |cop_name|
        assert_includes cop_names, cop_name,
                        "expected #{cop_name} in runner JSON file, got: #{cop_names.uniq.sort}"
      end

      unique_finding = RailsAudit::Normalizer.rubocop(raw, target_root: TARGET)
        .find { |finding| finding.rule == "Rails/UniqueValidationWithoutIndex" }

      refute_nil unique_finding
      assert_equal "high", unique_finding.impact
      assert_equal "rails", unique_finding.category
      assert_equal "app/models/user.rb", unique_finding.location.fetch(:file)
    end
  end

  private

  def with_environment(values)
    original = values.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
