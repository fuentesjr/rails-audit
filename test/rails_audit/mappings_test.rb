# frozen_string_literal: true

require "test_helper"

class MappingsTest < Minitest::Test
  def test_tables_are_scoped_to_the_pinned_tool_versions
    assert_equal(
      { brakeman: "8.0.5", rubocop: "1.88.2", reek: "6.5.0",
        schema: RailsAudit::VERSION, resilience: RailsAudit::VERSION },
      RailsAudit::Mappings::TOOL_VERSIONS
    )
  end

  def test_resilience_rules_and_threshold_are_explicit_versioned_data
    expected = {
      "Resilience/MissingStatementTimeout" => { impact: "high", confidence: "high" },
      "Resilience/StatementTimeoutTooHigh" => { impact: "medium", confidence: "high" },
      "Resilience/MissingConnectTimeout" => { impact: "medium", confidence: "high" },
      "Resilience/UnresolvableTimeoutValue" => { impact: "info", confidence: "low" },
      "Resilience/MissingRequestTimeout" => { impact: "high", confidence: "high" }
    }

    assert_equal({ statement_timeout_max_seconds: 30 }, RailsAudit::Mappings::RESILIENCE_THRESHOLDS)
    assert_equal expected.keys.sort, RailsAudit::Mappings::RESILIENCE_RULES.keys.sort
    expected.each do |rule, mapping|
      assert_mapping "resilience", rule, impact: mapping.fetch(:impact), category: "resilience"
      assert_equal mapping.fetch(:confidence), RailsAudit::Mappings.confidence(
        tool: "resilience", rule: rule
      )
    end
  end

  def test_brakeman_impact_and_confidence_are_independent
    assert_equal "critical", impact("brakeman", "SQL Injection")
    assert_equal "critical", impact("brakeman", "Command Injection")
    assert_equal "critical", impact("brakeman", "RCE")
    assert_equal "critical", impact("brakeman", "Cross-Site Scripting")
    assert_equal "high", impact("brakeman", "Mass Assignment")
    assert_equal "high", impact("brakeman", "File Access")
    assert_equal "high", impact("brakeman", "Unknown Warning")

    assert_equal "high", confidence("brakeman", "High")
    assert_equal "medium", confidence("brakeman", "Medium")
    assert_equal "low", confidence("brakeman", "Weak")
    assert_equal "medium", confidence("brakeman", "Unexpected")
  end

  def test_rubocop_uses_department_defaults
    assert_mapping "rubocop", "Security/IoMethods", impact: "high", category: "security"
    assert_mapping "rubocop", "Lint/UselessAssignment", impact: "high", category: "correctness"
    assert_mapping "rubocop", "Rails/SkipsModelValidations", impact: "low", category: "rails"
    assert_mapping "rubocop", "Performance/MapCompact", impact: "low", category: "performance"
    assert_mapping "rubocop", "Metrics/MethodLength", impact: "medium", category: "complexity"
    assert_mapping "rubocop", "Style/StringLiterals", impact: "info", category: "style"
    assert_mapping "rubocop", "Unknown/Example", impact: "low", category: "style"
    assert_equal "medium", confidence("rubocop", "fatal")
  end

  def test_rubocop_schema_and_migration_cops_override_department_defaults
    assert_mapping "rubocop", "Rails/UniqueValidationWithoutIndex",
                   impact: "high", category: "rails"
    %w[
      Rails/AddColumnIndex
      Rails/DangerousColumnNames
      Rails/MigrationClassName
      Rails/NotNullColumn
      Rails/ReversibleMigration
      Rails/ThreeStateBooleanColumn
    ].each do |rule|
      assert_mapping "rubocop", rule, impact: "medium", category: "rails"
    end
  end

  def test_minitest_cops_default_to_style_with_correctness_overrides
    assert_mapping "rubocop", "Minitest/AssertEqual", impact: "info", category: "style"
    assert_mapping "rubocop", "Minitest/UnreachableAssertion", impact: "high", category: "correctness"
    assert_mapping "rubocop", "Minitest/SkipEnsure", impact: "medium", category: "correctness"
    assert_mapping "rubocop", "Minitest/UselessAssertion", impact: "high", category: "correctness"
  end

  def test_custom_cops_override_department_default
    assert_mapping "rubocop", "RailsAudit/FatModel",
                   impact: "medium", category: "complexity"
    assert_mapping "rubocop", "RailsAudit/FatControllerAction",
                   impact: "medium", category: "complexity"
  end

  def test_resilience_cops_have_explicit_confidence_with_legacy_rubocop_fallback
    expected = {
      "RailsAudit/TimeoutModuleUse" => ["medium", "high"],
      "RailsAudit/NetHttpDefaultTimeouts" => ["medium", "high"],
      "RailsAudit/NetHttpMissingTimeout" => ["medium", "low"],
      "RailsAudit/FaradayMissingTimeout" => ["medium", "medium"],
      "RailsAudit/HttpartyMissingTimeout" => ["medium", "medium"],
      "RailsAudit/RackTimeoutDisabled" => ["high", "high"]
    }

    expected.each do |rule, (impact, confidence)|
      assert_mapping "rubocop", rule, impact: impact, category: "resilience"
      assert_equal confidence, RailsAudit::Mappings.confidence(tool: "rubocop", rule: rule)
    end
    assert_equal "medium", RailsAudit::Mappings.confidence(
      tool: "rubocop", rule: "RailsAudit/FatModel"
    )
    assert_equal "medium", RailsAudit::Mappings.confidence(
      tool: "rubocop", rule: "Style/StringLiterals"
    )
  end

  def test_reek_uses_rule_family_defaults
    assert_mapping "reek", "TooManyStatements", impact: "medium", category: "complexity"
    assert_mapping "reek", "FeatureEnvy", impact: "medium", category: "complexity"
    assert_mapping "reek", "DuplicateMethodCall", impact: "low", category: "design"
    assert_mapping "reek", "DataClump", impact: "low", category: "design"
    assert_mapping "reek", "NilCheck", impact: "low", category: "design"
    assert_mapping "reek", "MissingSafeMethod", impact: "low", category: "design"
    assert_mapping "reek", "UncommunicativeVariableName", impact: "info", category: "style"
    assert_mapping "reek", "UnknownSmell", impact: "low", category: "design"
    assert_equal "medium", confidence("reek", nil)
  end

  def test_schema_rules_have_explicit_mappings_and_passthrough_confidence
    assert_mapping "schema", "Schema/TableWithoutPrimaryKey",
                   impact: "high", category: "rails"
    assert_mapping "schema", "Schema/MismatchedForeignKeyType",
                   impact: "high", category: "rails"
    assert_mapping "schema", "Schema/UnindexedForeignKey",
                   impact: "medium", category: "performance"
    assert_mapping "schema", "Schema/ExtraneousIndex",
                   impact: "low", category: "performance"
    assert_mapping "schema", "Schema/ShortPrimaryKeyType",
                   impact: "medium", category: "rails"
    assert_equal "high", confidence("schema", "high")
    assert_equal "medium", confidence("schema", "medium")
  end

  def test_active_record_doctor_seeded_rules_match_static_schema_vocabulary
    assert_mapping "active_record_doctor", "unindexed_foreign_keys",
                   impact: "medium", category: "performance"
    assert_equal "medium", RailsAudit::Mappings.confidence(
      tool: "active_record_doctor", rule: "unindexed_foreign_keys"
    )

    assert_mapping "active_record_doctor", "missing_unique_indexes",
                   impact: "high", category: "rails"
    assert_equal "medium", RailsAudit::Mappings.confidence(
      tool: "active_record_doctor", rule: "missing_unique_indexes"
    )
  end

  private

  def impact(tool, rule)
    RailsAudit::Mappings.impact(tool: tool, rule: rule)
  end

  def confidence(tool, raw_confidence)
    RailsAudit::Mappings.confidence(tool: tool, raw_confidence: raw_confidence)
  end

  def assert_mapping(tool, rule, impact:, category:)
    assert_equal impact, RailsAudit::Mappings.impact(tool: tool, rule: rule)
    assert_equal category, RailsAudit::Mappings.category(tool: tool, rule: rule)
  end
end
