# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "test_helper"

class ResilienceAnalyzerTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/resilience", __dir__)

  def test_writes_deterministic_raw_json_and_returns_runner_result_shape
    with_target(database: "database_pg_with.yml", lockfile: "Gemfile.with_rack_timeout.lock") do |target|
      output_path = File.join(target, "raw", "resilience.json")
      result = RailsAudit::ResilienceAnalyzer.analyze(target: target, output_path: output_path)

      assert_equal %i[name version raw_count exit_code payload output_path warnings], result.keys
      assert_equal "resilience", result.fetch(:name)
      assert_equal RailsAudit::VERSION, result.fetch(:version)
      assert_equal 0, result.fetch(:exit_code)
      assert_equal result.fetch(:payload).size, result.fetch(:raw_count)
      assert_empty result.fetch(:payload)
      assert_empty result.fetch(:warnings)
      assert_equal result.fetch(:payload), JSON.parse(File.read(output_path))
    end
  end

  def test_postgresql_missing_timeouts_anchor_to_the_production_entry
    result = analyze(database: "database_pg_without.yml")

    assert_finding result, "Resilience/MissingStatementTimeout", "production", 1, "high"
    assert_finding result, "Resilience/MissingConnectTimeout", "production", 1, "high"
  end

  def test_postgresql_statement_timeout_above_the_threshold_reports_observed_value
    finding = assert_finding(
      analyze(database: "database_pg_too_high.yml"),
      "Resilience/StatementTimeoutTooHigh", "production", 5, "high"
    )

    assert_includes finding.fetch("message"), "31s"
    assert_includes finding.fetch("message"), "≤ 30s"
  end

  def test_zero_statement_timeout_is_reported_as_explicitly_disabled
    finding = assert_finding(
      analyze(database: "database_pg_disabled.yml"),
      "Resilience/MissingStatementTimeout", "production", 5, "high"
    )

    assert_includes finding.fetch("message"), "0"
    assert_includes finding.fetch("message"), "explicitly disabled"
  end

  def test_erb_timeout_value_is_unresolvable_and_is_never_evaluated
    finding = assert_finding(
      analyze(database: "database_pg_erb.yml"),
      "Resilience/UnresolvableTimeoutValue", "production", 5, "low"
    )

    assert_includes finding.fetch("message"), "<%="
    refute_includes rules(analyze(database: "database_pg_erb.yml")),
                    "Resilience/MissingStatementTimeout"
  end

  def test_unknown_duration_is_unresolvable
    finding = assert_finding(
      analyze(database: "database_pg_invalid_value.yml"),
      "Resilience/UnresolvableTimeoutValue", "production", 5, "low"
    )

    assert_includes finding.fetch("message"), "eventually"
  end

  def test_multi_database_entries_use_path_discriminators_and_entry_lines
    result = analyze(database: "database_multi.yml")

    missing = assert_finding(
      result, "Resilience/MissingConnectTimeout", "production.replica", 10, "high"
    )
    high = assert_finding(
      result, "Resilience/StatementTimeoutTooHigh", "production.replica", 13, "high"
    )

    assert_equal [missing, high], result.fetch(:payload)
    refute(result.fetch(:payload).any? do |row|
      row.fetch("discriminator").start_with?("production.primary")
    end)
  end

  def test_mysql_timeout_units_and_select_only_limitation
    result = analyze(database: "database_mysql2.yml")
    mysql = assert_finding(
      result, "Resilience/StatementTimeoutTooHigh", "production.primary", 6, "high"
    )
    mariadb = assert_finding(
      result, "Resilience/StatementTimeoutTooHigh", "production.replica", 11, "high"
    )

    assert_includes mysql.fetch("message"), "40000"
    assert_includes mysql.fetch("message"), "SELECT-only"
    assert_includes mysql.fetch("message"), "writes stay unbounded"
    assert_includes mariadb.fetch("message"), "30.5"
    refute_includes mariadb.fetch("message"), "SELECT-only"
  end

  def test_unknown_adapter_skips_entry_with_a_named_warning
    result = analyze(database: "database_unknown.yml")

    assert_empty result.fetch(:payload)
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "production"
    assert_includes result.fetch(:warnings).first, "oracle_enhanced"
  end

  def test_sqlite_is_skipped_without_a_warning
    result = analyze(database: "database_sqlite.yml")

    assert_empty result.fetch(:payload)
    assert_empty result.fetch(:warnings)
  end

  def test_invalid_yaml_disables_database_checks_with_a_reason
    result = analyze(database: "database_unparseable.yml")

    assert_empty result.fetch(:payload)
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "config/database.yml"
    assert_includes result.fetch(:warnings).first, "invalid YAML"
  end

  def test_structural_erb_disables_database_checks_without_evaluation
    result = analyze(database: "database_erb_structure.yml")

    assert_empty result.fetch(:payload)
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "ERB beyond value positions"
  end

  def test_erb_replacing_production_mapping_disables_database_checks_with_a_reason
    result = analyze(database: "database_erb_production_value.yml")

    assert_empty result.fetch(:payload)
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "ERB beyond value positions"
  end

  def test_unresolved_yaml_alias_disables_database_checks_with_a_reason
    result = analyze(database: "database_unresolved_alias.yml")

    assert_empty result.fetch(:payload)
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "invalid YAML"
    assert_includes result.fetch(:warnings).first, "missing"
  end

  def test_missing_database_config_and_lockfile_each_emit_inactivity_warning
    result = analyze(lockfile: nil)

    assert_empty result.fetch(:payload)
    assert_equal 2, result.fetch(:warnings).size
    assert(result.fetch(:warnings).any? do |warning|
      warning.include?("config/database.yml not found")
    end)
    assert(result.fetch(:warnings).any? { |warning| warning.include?("Gemfile.lock not found") })
  end

  def test_missing_request_timeout_is_anchored_to_lockfile_line_one
    result = analyze(lockfile: "Gemfile.without_request_timeout.lock")
    finding = assert_finding(
      result, "Resilience/MissingRequestTimeout", "request-timeout", 1, "high",
      file: "Gemfile.lock"
    )

    assert_includes finding.fetch("message"), "rack-timeout"
    assert_includes finding.fetch("message"), "slowpoke"
  end

  def test_rack_timeout_or_slowpoke_each_satisfy_request_timeout_detection
    rack_result = analyze(lockfile: "Gemfile.with_rack_timeout.lock")
    slowpoke_result = analyze(lockfile: "Gemfile.with_slowpoke.lock")

    refute_includes rules(rack_result), "Resilience/MissingRequestTimeout"
    refute_includes rules(slowpoke_result), "Resilience/MissingRequestTimeout"
  end

  def test_url_only_top_level_production_warns_with_its_path
    result = analyze_source(database: <<~YAML)
      production:
        url: postgres://user:password@db.example/app
    YAML

    assert_empty result.fetch(:payload)
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "production"
    assert_includes result.fetch(:warnings).first, "no statically visible adapter"
  end

  def test_absent_production_environment_warns_that_it_is_not_defined
    result = analyze_source(database: <<~YAML)
      development:
        adapter: sqlite3
    YAML

    assert_empty result.fetch(:payload)
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "production environment is not defined"
    refute_includes result.fetch(:warnings).first, "could not be statically parsed"
  end

  def test_null_production_environment_warns_that_it_is_not_defined
    result = analyze_source(database: <<~YAML)
      production:
    YAML

    assert_empty result.fetch(:payload)
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "production environment is not defined"
    refute_includes result.fetch(:warnings).first, "could not be statically parsed"
  end

  def test_url_only_multi_database_entry_warns_while_adapter_sibling_is_audited
    result = analyze_source(database: <<~YAML)
      production:
        primary:
          adapter: postgresql
          database: app_production
        replica:
          url: postgres://user:password@replica.example/app
    YAML

    assert_finding result, "Resilience/MissingStatementTimeout", "production.primary", 2, "high"
    assert_finding result, "Resilience/MissingConnectTimeout", "production.primary", 2, "high"
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "production.replica"
    assert_includes result.fetch(:warnings).first, "no statically visible adapter"
  end

  def test_crlf_lockfile_with_rack_timeout_does_not_report_missing_request_timeout
    lockfile = File.binread(File.join(FIXTURES, "Gemfile.with_rack_timeout.lock"))
                   .gsub("\n", "\r\n")
    result = analyze_source(database: nil, lockfile: lockfile)

    refute_includes rules(result), "Resilience/MissingRequestTimeout"
  end

  def test_negative_statement_timeout_is_not_a_valid_finite_timeout
    result = analyze_source(database: <<~YAML)
      production:
        adapter: postgresql
        connect_timeout: 5
        variables:
          statement_timeout: -5000
    YAML
    finding = assert_finding(
      result, "Resilience/MissingStatementTimeout", "production", 5, "high"
    )

    assert_includes finding.fetch("message"), "-5000"
    assert_includes finding.fetch("message"), "not a valid finite timeout"
  end

  def test_zero_connect_timeout_reports_indefinite_wait_with_observed_value
    result = analyze_source(database: <<~YAML)
      production:
        adapter: postgresql
        connect_timeout: 0
        variables:
          statement_timeout: 5s
    YAML
    finding = assert_finding(
      result, "Resilience/MissingConnectTimeout", "production", 3, "high"
    )

    assert_includes finding.fetch("message"), "0"
    assert_includes finding.fetch("message"), "wait indefinitely"
  end

  def test_unresolved_alias_on_one_sibling_warns_while_other_sibling_is_audited
    result = analyze_source(database: <<~YAML)
      production:
        primary:
          adapter: postgresql
          database: app_production
        replica:
          <<: *missing
    YAML

    assert_finding result, "Resilience/MissingStatementTimeout", "production.primary", 2, "high"
    assert_finding result, "Resilience/MissingConnectTimeout", "production.primary", 2, "high"
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "production.replica"
    assert_includes result.fetch(:warnings).first, "unresolved alias"
    assert_includes result.fetch(:warnings).first, "missing"
  end

  def test_unresolved_value_alias_on_one_sibling_warns_while_other_sibling_is_audited
    result = analyze_source(database: <<~YAML)
      production:
        primary:
          adapter: postgresql
          database: app_production
        replica:
          adapter: *missing
    YAML

    assert_finding result, "Resilience/MissingStatementTimeout", "production.primary", 2, "high"
    assert_finding result, "Resilience/MissingConnectTimeout", "production.primary", 2, "high"
    assert_equal 1, result.fetch(:warnings).size
    assert_includes result.fetch(:warnings).first, "production.replica"
    assert_includes result.fetch(:warnings).first, "unresolved alias"
    assert_includes result.fetch(:warnings).first, "missing"
  end

  def test_postgresql_bare_integer_millisecond_boundary
    at_threshold = analyze_source(database: database_with_statement_timeout("30000"))
    above_threshold = analyze_source(database: database_with_statement_timeout("30001"))

    refute_includes rules(at_threshold), "Resilience/StatementTimeoutTooHigh"
    high = assert_finding(
      above_threshold, "Resilience/StatementTimeoutTooHigh", "production", 5, "high"
    )
    assert_includes high.fetch("message"), "30001"
    assert_includes high.fetch("message"), "≤ 30s"
  end

  def test_mysql_missing_statement_variables_includes_select_only_limitation
    result = analyze_source(database: <<~YAML)
      production:
        adapter: mysql2
        connect_timeout: 5
    YAML
    finding = assert_finding(
      result, "Resilience/MissingStatementTimeout", "production", 1, "high"
    )

    assert_includes finding.fetch("message"), "SELECT-only"
    assert_includes finding.fetch("message"), "writes stay unbounded"
  end

  private

  def analyze_source(database:, lockfile: File.binread(File.join(FIXTURES, "Gemfile.with_rack_timeout.lock")))
    result = nil
    Dir.mktmpdir do |target|
      if database
        FileUtils.mkdir_p(File.join(target, "config"))
        File.write(File.join(target, "config", "database.yml"), database)
      end
      File.binwrite(File.join(target, "Gemfile.lock"), lockfile) if lockfile
      result = RailsAudit::ResilienceAnalyzer.analyze(
        target: target, output_path: File.join(target, "raw", "resilience.json")
      )
    end
    result
  end

  def database_with_statement_timeout(value)
    <<~YAML
      production:
        adapter: postgresql
        connect_timeout: 5
        variables:
          statement_timeout: #{value}
    YAML
  end

  def analyze(database: nil, lockfile: "Gemfile.with_rack_timeout.lock")
    result = nil
    with_target(database: database, lockfile: lockfile) do |target|
      result = RailsAudit::ResilienceAnalyzer.analyze(
        target: target, output_path: File.join(target, "raw", "resilience.json")
      )
    end
    result
  end

  def assert_finding(result, rule, discriminator, line, confidence, file: "config/database.yml")
    finding = result.fetch(:payload).find do |row|
      row.fetch("rule") == rule && row.fetch("discriminator") == discriminator
    end

    refute_nil finding, "expected #{rule} for #{discriminator}"
    assert_equal file, finding.fetch("file")
    assert_equal line, finding.fetch("line")
    assert_equal confidence, finding.fetch("confidence")
    finding
  end

  def rules(result)
    result.fetch(:payload).map { |row| row.fetch("rule") }
  end

  def with_target(database: nil, lockfile: nil)
    Dir.mktmpdir do |target|
      if database
        FileUtils.mkdir_p(File.join(target, "config"))
        FileUtils.cp(File.join(FIXTURES, database), File.join(target, "config", "database.yml"))
      end
      FileUtils.cp(File.join(FIXTURES, lockfile), File.join(target, "Gemfile.lock")) if lockfile
      yield target
    end
  end
end
