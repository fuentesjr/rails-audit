# frozen_string_literal: true

module RailsAudit
  module Mappings
    TOOL_VERSIONS = {
      brakeman: "8.0.5",
      rubocop: "1.88.2",
      reek: "6.5.0"
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
      "Naming" => { impact: "info", category: "style" }.freeze
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
      "RailsAudit/ServiceObject" => { impact: "low", category: "design" }.freeze
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

    module_function

    def impact(tool:, rule:)
      case tool
      when "brakeman" then BRAKEMAN_IMPACT.fetch(rule, "high")
      when "rubocop" then rubocop_mapping(rule).fetch(:impact)
      when "reek" then reek_mapping(rule).fetch(:impact)
      else "low"
      end
    end

    def confidence(tool:, raw_confidence: nil)
      return BRAKEMAN_CONFIDENCE.fetch(raw_confidence, "medium") if tool == "brakeman"

      "medium"
    end

    def category(tool:, rule:)
      case tool
      when "brakeman" then "security"
      when "rubocop" then rubocop_mapping(rule).fetch(:category)
      when "reek" then reek_mapping(rule).fetch(:category)
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
