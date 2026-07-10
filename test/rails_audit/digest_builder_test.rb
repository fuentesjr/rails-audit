# frozen_string_literal: true

require "json"
require "test_helper"

class DigestBuilderTest < Minitest::Test
  TARGET_ROOT = "target/lobsters"

  def test_real_fixture_marks_both_truncation_paths_with_exact_counts
    document = fixture_document
    digest = RailsAudit::DigestBuilder.build(document)

    assert_operator digest.length, :<=, 15_000
    assert_includes digest, "Total findings: 12903"
    assert_includes digest, "critical: 23"
    assert_includes digest, "high: 55"
    assert_includes digest, "brakeman: 27 raw findings"
    assert_includes digest, "rubocop: 11176 raw findings"
    assert_includes digest, "reek: 1700 raw findings"

    individual_marker = digest.lines.find { |line| line.include?("critical/high findings dropped") }
    refute_nil individual_marker
    dropped, total = individual_marker.match(/(\d+) of (\d+) critical\/high findings dropped/).captures.map(&:to_i)
    visible = digest.lines.count { |line| line.start_with?("- [critical/", "- [high/") }
    assert_equal 78, total
    assert_equal total - visible, dropped
    assert_rule_breakdown_matches_individual_overflow(document, visible, individual_marker)

    aggregate_marker = digest.lines.find { |line| line.include?("aggregate rows dropped") }
    refute_nil aggregate_marker
    assert_includes aggregate_marker, "66 of 106 aggregate rows dropped (490 findings)"
    assert_rule_breakdown_matches_aggregate_overflow(document, aggregate_marker)
  end

  def test_final_backstop_is_explicit_and_reports_exact_character_counts
    document = fixture_document.merge(target: "x" * 20_000)
    digest = RailsAudit::DigestBuilder.build(document)

    assert_equal 15_000, digest.length
    marker = digest[/\[FINAL HARD-CAP BACKSTOP: \d+ of \d+ characters dropped\]\z/]
    refute_nil marker
    dropped, total = marker.match(/(\d+) of (\d+) characters dropped/).captures.map(&:to_i)
    assert_equal total, (15_000 - marker.length) + dropped
  end

  private

  def assert_rule_breakdown_matches_individual_overflow(document, visible_count, marker)
    individual = document.fetch(:findings).select { |finding| %w[critical high].include?(finding.fetch(:impact)) }
    omitted = canonical_findings(individual).drop(visible_count)
    expected = omitted.group_by { |finding| finding.fetch(:rule) }
                      .transform_values(&:size)
                      .sort.to_h

    assert_equal expected, marker_breakdown(marker)
  end

  def canonical_findings(findings)
    impact_order = %w[critical high medium low info]
    findings.sort_by do |finding|
      location = finding.fetch(:location)
      [impact_order.index(finding.fetch(:impact)), finding.fetch(:category), location.fetch(:file),
       location.fetch(:start_line), finding.fetch(:tool), finding.fetch(:rule), finding.fetch(:message),
       finding.fetch(:id)]
    end
  end

  def assert_rule_breakdown_matches_aggregate_overflow(document, marker)
    findings = document.fetch(:findings).reject { |finding| %w[critical high].include?(finding.fetch(:impact)) }
    groups = findings.group_by do |finding|
      [finding.fetch(:category), finding.fetch(:impact), finding.fetch(:tool), finding.fetch(:rule)]
    end
    omitted = groups.map { |key, group| [key, group.size] }
                    .sort_by { |(category, impact, tool, rule), count| [-count, category, impact, tool, rule] }
                    .drop(40)
    expected = omitted.group_by { |((_, _, _, rule), _)| rule }
                      .transform_values { |rows| rows.sum { |(_, count)| count } }
                      .sort.to_h

    assert_equal expected, marker_breakdown(marker)
  end

  def marker_breakdown(marker)
    marker.split("Rule counts: ", 2).fetch(1).delete_suffix("]\n").split("; ").to_h do |entry|
      rule, count = entry.split("=", 2)
      [rule, Integer(count)]
    end
  end

  def fixture_document
    RailsAudit::Normalizer.document(
      target: TARGET_ROOT,
      toolchain: { ruby: "4.0.1" },
      tools: [
        { name: "brakeman", version: "8.0.5", raw_count: 27, exit_code: 3 },
        { name: "rubocop", version: "1.88.2", raw_count: 11_176, exit_code: 1 },
        { name: "reek", version: "6.5.0", raw_count: 1_700, exit_code: 2 }
      ],
      findings: RailsAudit::Normalizer.normalize(
        brakeman: raw_fixture("brakeman.json"),
        rubocop: raw_fixture("rubocop.json"),
        reek: raw_fixture("reek.json"),
        target_root: TARGET_ROOT
      )
    )
  end

  def raw_fixture(name)
    JSON.parse(File.read(File.expand_path("../fixtures/raw/#{name}", __dir__)))
  end
end
