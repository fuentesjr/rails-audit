# frozen_string_literal: true

module RailsAudit
  module Mappings
    TOOL_VERSIONS = {
      brakeman: "8.0.5",
      rubocop: "1.88.2",
      reek: "6.5.0",
      schema: RailsAudit::VERSION
    }.freeze

    BRAKEMAN_IMPACT = {
      "SQL Injection" => "critical",
      "Command Injection" => "critical",
      "RCE" => "critical",
      "Remote Code Execution" => "critical",
      "Unsafe Deserialization" => "critical",
      "Cross-Site Scripting" => "critical",
      "Cross Site Scripting" => "critical",
      "Mass Assignment" => "high",
      "Open Redirect" => "high",
      "Redirect" => "high",
      "File Access" => "high"
    }.freeze

    BRAKEMAN_CONFIDENCE = {
      "High" => "high",
      "Medium" => "medium",
      "Weak" => "low"
    }.freeze

    RUBOCOP_DEPARTMENTS = {
      "Security" => { impact: "high", category: "security" }.freeze,
      "Lint" => { impact: "high", category: "correctness" }.freeze,
      "Rails" => { impact: "low", category: "rails" }.freeze,
      "Performance" => { impact: "low", category: "performance" }.freeze,
      "Metrics" => { impact: "medium", category: "complexity" }.freeze,
      "Style" => { impact: "info", category: "style" }.freeze,
      "Layout" => { impact: "info", category: "style" }.freeze,
      "Naming" => { impact: "info", category: "style" }.freeze,
      # rubocop-minitest is mostly assertion-style guidance (Minitest/AssertNil, etc.) — info/
      # style is the right default. The genuine correctness-shaped cops (dead assertions,
      # `ensure` skipped under `skip`) are overridden individually below so they don't fall
      # into this style bucket, per DESIGN.md §8's adoption condition.
      "Minitest" => { impact: "info", category: "style" }.freeze
    }.freeze
    RUBOCOP_DEFAULT = { impact: "low", category: "style" }.freeze
    RUBOCOP_RULES = {
      "Rails/UniqueValidationWithoutIndex" => { impact: "high", category: "rails" }.freeze,
      "Rails/AddColumnIndex" => { impact: "medium", category: "rails" }.freeze,
      "Rails/DangerousColumnNames" => { impact: "medium", category: "rails" }.freeze,
      "Rails/MigrationClassName" => { impact: "medium", category: "rails" }.freeze,
      "Rails/NotNullColumn" => { impact: "medium", category: "rails" }.freeze,
      "Rails/ReversibleMigration" => { impact: "medium", category: "rails" }.freeze,
      "Rails/ThreeStateBooleanColumn" => { impact: "medium", category: "rails" }.freeze,
      "RailsAudit/FatModel" => { impact: "medium", category: "complexity" }.freeze,
      "RailsAudit/FatControllerAction" => { impact: "medium", category: "complexity" }.freeze,
      "Minitest/UnreachableAssertion" => { impact: "high", category: "correctness" }.freeze,
      "Minitest/SkipEnsure" => { impact: "medium", category: "correctness" }.freeze,
      "Minitest/UselessAssertion" => { impact: "high", category: "correctness" }.freeze,
    }.freeze

    REEK_COMPLEXITY_RULES = %w[
      ClassLength FeatureEnvy LargeClass LongParameterList NestedIterators
      RepeatedConditional TooManyConstants TooManyInstanceVariables TooManyMethods
      TooManyStatements
    ].freeze

    REEK_DESIGN_RULES = %w[
      Attribute ControlParameter DataClump DuplicateMethodCall MissingSafeMethod NilCheck
      UtilityFunction
    ].freeze

    REEK_NAMING_RULES = %w[
      IrresponsibleModule UncommunicativeMethodName UncommunicativeModuleName
      UncommunicativeParameterName UncommunicativeVariableName
    ].freeze
    REEK_RULE_FAMILIES = {
      complexity: REEK_COMPLEXITY_RULES,
      design: REEK_DESIGN_RULES,
      naming: REEK_NAMING_RULES
    }.freeze
    REEK_FAMILY_MAPPINGS = {
      complexity: { impact: "medium", category: "complexity" }.freeze,
      design: { impact: "low", category: "design" }.freeze,
      naming: { impact: "info", category: "style" }.freeze
    }.freeze
    SCHEMA_RULES = {
      "Schema/TableWithoutPrimaryKey" => { impact: "high", category: "rails" }.freeze,
      "Schema/MismatchedForeignKeyType" => { impact: "high", category: "rails" }.freeze,
      "Schema/UnindexedForeignKey" => { impact: "medium", category: "performance" }.freeze,
      "Schema/ExtraneousIndex" => { impact: "low", category: "performance" }.freeze,
      "Schema/ShortPrimaryKeyType" => { impact: "medium", category: "rails" }.freeze
    }.freeze
    ACTIVE_RECORD_DOCTOR_RULES = {
      "missing_presence_validation" => { impact: "medium", category: "rails", confidence: "medium" }.freeze,
      "missing_foreign_keys" => { impact: "high", category: "rails", confidence: "high" }.freeze,
      "missing_unique_indexes" => { impact: "high", category: "rails", confidence: "medium" }.freeze,
      "incorrect_boolean_presence_validation" => { impact: "medium", category: "correctness", confidence: "high" }.freeze,
      "incorrect_length_validation" => { impact: "medium", category: "correctness", confidence: "high" }.freeze,
      "extraneous_indexes" => { impact: "low", category: "performance", confidence: "high" }.freeze,
      "unindexed_deleted_at" => { impact: "medium", category: "performance", confidence: "medium" }.freeze,
      "undefined_table_references" => { impact: "high", category: "correctness", confidence: "high" }.freeze,
      "missing_non_null_constraint" => { impact: "high", category: "rails", confidence: "high" }.freeze,
      "unindexed_foreign_keys" => { impact: "medium", category: "performance", confidence: "medium" }.freeze,
      "incorrect_dependent_option" => { impact: "medium", category: "rails", confidence: "medium" }.freeze,
      "short_primary_key_type" => { impact: "medium", category: "rails", confidence: "high" }.freeze,
      "mismatched_foreign_key_type" => { impact: "high", category: "rails", confidence: "high" }.freeze,
      "table_without_primary_key" => { impact: "high", category: "rails", confidence: "high" }.freeze,
      "table_without_timestamps" => { impact: "low", category: "rails", confidence: "high" }.freeze
    }.freeze

    module_function

    def impact(tool:, rule:)
      case tool
      when "brakeman" then BRAKEMAN_IMPACT.fetch(rule, "high")
      when "rubocop" then rubocop_mapping(rule).fetch(:impact)
      when "reek" then reek_mapping(rule).fetch(:impact)
      when "schema" then SCHEMA_RULES.fetch(rule).fetch(:impact)
      when "active_record_doctor" then ACTIVE_RECORD_DOCTOR_RULES.fetch(rule).fetch(:impact)
      else "low"
      end
    end

    def confidence(tool:, rule: nil, raw_confidence: nil)
      return BRAKEMAN_CONFIDENCE.fetch(raw_confidence, "medium") if tool == "brakeman"
      return raw_confidence if tool == "schema"
      if tool == "active_record_doctor"
        return ACTIVE_RECORD_DOCTOR_RULES.fetch(rule).fetch(:confidence)
      end

      "medium"
    end

    def category(tool:, rule:)
      case tool
      when "brakeman" then "security"
      when "rubocop" then rubocop_mapping(rule).fetch(:category)
      when "reek" then reek_mapping(rule).fetch(:category)
      when "schema" then SCHEMA_RULES.fetch(rule).fetch(:category)
      when "active_record_doctor" then ACTIVE_RECORD_DOCTOR_RULES.fetch(rule).fetch(:category)
      else "style"
      end
    end

    def rubocop_mapping(rule)
      department = rule.split("/", 2).first
      RUBOCOP_RULES.fetch(rule) { RUBOCOP_DEPARTMENTS.fetch(department, RUBOCOP_DEFAULT) }
    end
    private_class_method :rubocop_mapping

    def reek_mapping(rule)
      # DESIGN section 9 leaves NilCheck and MissingSafeMethod ambiguous; Phase 1 uses design.
      family = REEK_RULE_FAMILIES.find { |_name, rules| rules.include?(rule) }&.first || :design
      REEK_FAMILY_MAPPINGS.fetch(family)
    end
    private_class_method :reek_mapping
  end
end
