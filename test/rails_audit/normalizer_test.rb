# frozen_string_literal: true

require "json"
require "test_helper"

class NormalizerTest < Minitest::Test
  TARGET_ROOT = "target/lobsters"

  def test_normalizes_all_brakeman_warnings
    raw = raw_fixture("brakeman.json")
    findings = RailsAudit::Normalizer.brakeman(raw, target_root: TARGET_ROOT)
    sql_injection = findings.find do |finding|
      finding.rule == "SQL Injection" && finding.location[:start_line] == 716
    end

    assert_equal raw.fetch("warnings").size, findings.size
    assert_equal "01fb46929f85689fc7a2696d605c5a4e1a25fb137aa22b885ee3487a88156eec",
                 sql_injection.native_fingerprint
    assert_equal "critical", sql_injection.impact
    assert_equal "medium", sql_injection.confidence
    assert_equal "security", sql_injection.category
    assert_equal(
      { file: "app/models/story.rb", start_line: 716, end_line: 716, column: nil, lines: nil },
      sql_injection.location
    )
    assert_equal({ class: "Story", method: "update_score_and_recalculate!" }, sql_injection.context)
  end

  def test_normalizes_every_nested_rubocop_offense
    raw = raw_fixture("rubocop.json")
    findings = RailsAudit::Normalizer.rubocop(raw, target_root: TARGET_ROOT)
    first_raw_file = raw.fetch("files").first
    first_raw_offense = first_raw_file.fetch("offenses").first
    finding = findings.first

    assert_equal raw.dig("summary", "offense_count"), findings.size
    assert_equal first_raw_offense.fetch("cop_name"), finding.rule
    expected_file = first_raw_file.fetch("path").delete_prefix("#{TARGET_ROOT}/")
    assert_equal expected_file, finding.location[:file]
    assert_equal first_raw_offense.dig("location", "start_line"), finding.location[:start_line]
    assert_equal first_raw_offense.dig("location", "last_line"), finding.location[:end_line]
    assert_equal first_raw_offense.dig("location", "start_column"), finding.location[:column]
    assert_nil finding.native_fingerprint
    assert_nil finding.context
  end

  def test_normalizes_rubocop_confidence_from_the_rule_mapping
    raw = {
      "files" => [
        {
          "path" => "target/lobsters/app/services/client.rb",
          "offenses" => [
            rubocop_offense("RailsAudit/NetHttpMissingTimeout", 3),
            rubocop_offense("RailsAudit/TimeoutModuleUse", 8),
            rubocop_offense("Style/StringLiterals", 13)
          ]
        }
      ]
    }

    findings = RailsAudit::Normalizer.rubocop(raw, target_root: TARGET_ROOT)

    assert_equal %w[low high medium], findings.map(&:confidence)
  end

  def test_normalizes_reek_ranges_and_keeps_long_line_sets
    raw = raw_fixture("reek.json")
    findings = RailsAudit::Normalizer.reek(raw, target_root: TARGET_ROOT)
    raw_smell = raw.find { |smell| smell.fetch("lines").size > 2 }
    finding = findings.find { |candidate| candidate.message == raw_smell.fetch("message") }
    sorted_lines = raw_smell.fetch("lines").sort

    assert_equal raw.size, findings.size
    assert_equal raw_smell.fetch("source").delete_prefix("#{TARGET_ROOT}/"), finding.location[:file]
    assert_equal sorted_lines.min, finding.location[:start_line]
    assert_equal sorted_lines.max, finding.location[:end_line]
    assert_nil finding.location[:column]
    assert_equal sorted_lines, finding.location[:lines]
    assert_nil finding.native_fingerprint
    assert_nil finding.context
  end

  def test_reek_omits_short_line_sets_and_sorts_unordered_long_sets
    raw = [
      { "source" => "target/lobsters/short.rb", "lines" => [9, 3],
        "smell_type" => "FeatureEnvy", "message" => "short" },
      { "source" => "target/lobsters/long.rb", "lines" => [9, 3, 5],
        "smell_type" => "FeatureEnvy", "message" => "long" }
    ]

    short, long = RailsAudit::Normalizer.reek(raw, target_root: TARGET_ROOT)

    assert_equal({ file: "short.rb", start_line: 3, end_line: 9, column: nil, lines: nil },
                 short.location)
    assert_equal [3, 5, 9], long.location[:lines]
  end

  def test_combined_normalization_applies_canonical_sort
    findings = RailsAudit::Normalizer.normalize(
      brakeman: raw_fixture("brakeman.json"),
      rubocop: raw_fixture("rubocop.json"),
      reek: raw_fixture("reek.json"),
      schema: [],
      target_root: TARGET_ROOT
    )

    expected_order = findings.sort_by do |finding|
      [finding.location[:file], finding.location[:start_line], finding.tool, finding.rule]
    end
    assert_equal 27 + 11_176 + 1_700, findings.size
    assert_equal expected_order, findings
  end

  def test_normalizes_resilience_rows_using_each_rows_file_and_rule_mapping
    payload = [
      {
        "rule" => "Resilience/MissingRequestTimeout",
        "message" => "missing middleware",
        "file" => "Gemfile.lock",
        "line" => 1,
        "discriminator" => "request-timeout",
        "confidence" => "high"
      },
      {
        "rule" => "Resilience/UnresolvableTimeoutValue",
        "message" => "dynamic value",
        "file" => "config/database.yml",
        "line" => 9,
        "discriminator" => "production.primary",
        "confidence" => "low"
      }
    ]

    request_timeout, database = RailsAudit::Normalizer.resilience(payload, target_root: TARGET_ROOT)

    assert_equal "Gemfile.lock", request_timeout.location.fetch(:file)
    assert_equal "high", request_timeout.impact
    assert_equal "high", request_timeout.confidence
    assert_equal "resilience", request_timeout.category
    assert_equal "config/database.yml", database.location.fetch(:file)
    assert_equal "info", database.impact
    assert_equal "low", database.confidence
    assert_equal "production.primary", database.discriminator
  end

  def test_builds_serializable_top_level_document_without_runtime
    finding = RailsAudit::Normalizer.brakeman(
      { "warnings" => [raw_fixture("brakeman.json").fetch("warnings").first] },
      target_root: TARGET_ROOT
    ).first
    document = RailsAudit::Normalizer.document(
      target: TARGET_ROOT,
      toolchain: { ruby: "4.0.1" },
      tools: [
        { name: "brakeman", version: "8.0.5", raw_count: 1, exit_code: 3, runtime_s: 1.2 }
      ],
      findings: [finding]
    )

    assert_equal %i[target toolchain tools warnings findings], document.keys
    assert_equal finding.to_h, document.fetch(:findings).first
    assert_empty document.fetch(:warnings)
    refute_includes JSON.generate(document), "runtime_s"
  end

  def test_document_passes_through_given_warnings
    document = RailsAudit::Normalizer.document(
      target: TARGET_ROOT,
      toolchain: { ruby: "4.0.1" },
      tools: [],
      findings: [],
      warnings: ["db/schema.rb not found"]
    )

    assert_equal ["db/schema.rb not found"], document.fetch(:warnings)
  end

  private

  def raw_fixture(name)
    path = File.expand_path("../fixtures/raw/#{name}", __dir__)
    JSON.parse(File.read(path))
  end

  def rubocop_offense(cop_name, line)
    {
      "cop_name" => cop_name,
      "message" => "example",
      "location" => {
        "start_line" => line,
        "last_line" => line,
        "start_column" => 1
      }
    }
  end
end
