# frozen_string_literal: true

require "json"
require "test_helper"

class ReportTest < Minitest::Test
  TARGET_ROOT = "target/lobsters"

  def test_renders_impact_first_report_from_real_fixtures
    document = fixture_document
    report = RailsAudit::Report.render(document)
    findings = document.fetch(:findings)

    assert_includes report, "# rails-audit report\n\nTarget: #{TARGET_ROOT}"
    assert_includes report, "- brakeman 8.0.5 — 27 findings (exit 3)"
    assert_includes report, "- rubocop 1.88.2 — 11176 findings (exit 1)"
    assert_includes report, "- reek 6.5.0 — 1700 findings (exit 2)"
    refute_includes report, "runtime_s"

    assert_equal 1, report.scan(/^## Critical & High$/).size
    assert_operator report.index("## Critical & High"), :<, report.index("## Security")
    assert_includes report, "### Critical"
    assert_includes report, "#### security (23)"
    assert_includes report, "### High"
    assert_includes report, "#### correctness (51)"

    lint_finding = findings.find { |finding| finding[:rule].start_with?("Lint/") }
    location = lint_finding.fetch(:location)
    assert_includes section(report, "Critical & High"),
                    "- `#{location[:file]}:#{location[:start_line]}` **#{lint_finding[:rule]}** — " \
                    "#{lint_finding[:message]} (confidence: #{lint_finding[:confidence]})"

    correctness = section(report, "Correctness")
    assert_includes correctness,
                    "Critical/High: 51 — listed individually in the Critical & High section above."
    assert_includes correctness, "| Impact | Rule | Count |"
    refute_match(/^- `/m, correctness)

    assert_includes report, "## Totals by impact"
    assert_includes report, "| Critical | 23 |"
    assert_includes report, "| High | 55 |"
    assert_includes report, "## Totals by confidence"
    assert_equal 2, report.scan("| **Total** | #{findings.size} |").size
  end

  def test_real_fixture_overflow_markers_show_exact_dropped_counts
    report = RailsAudit::Report.render(fixture_document)
    leading = section(report, "Critical & High")

    assert_includes leading, "#### correctness (51)"
    listing_count = subgroup(leading, "correctness").lines.count { |line| line.start_with?("- `") }
    assert_equal 25, listing_count
    assert_includes subgroup(leading, "correctness"), "- …and 26 more"

    style = section(report, "Style")
    assert_includes style, "- …and 63 more rules (953 findings)"
    assert_includes style, "Total: 10944 findings."
  end

  def test_zero_critical_or_high_findings_is_explicit
    report = RailsAudit::Report.render(document_with([
      finding(category: "style", impact: "info", rule: "Style/Foo", file: "a.rb", start_line: 1)
    ]))

    assert_includes section(report, "Critical & High"), "None."
    assert_includes section(report, "Style"), "Critical/High: 0."
  end

  def test_aggregate_rows_sort_by_impact_then_count_then_rule
    findings = [
      *rule_group("InfoPopular", 20, impact: "info"),
      *rule_group("MediumZ", 2, impact: "medium"),
      *rule_group("MediumA", 2, impact: "medium"),
      *rule_group("LowRule", 10, impact: "low")
    ]
    rows = section(RailsAudit::Report.render(document_with(findings)), "Style")
           .lines.grep(/^\| (?:Critical|High|Medium|Low|Info) /)

    assert_equal [
      "| Medium | MediumA | 2 |\n",
      "| Medium | MediumZ | 2 |\n",
      "| Low | LowRule | 10 |\n",
      "| Info | InfoPopular | 20 |\n"
    ], rows
  end

  def test_individual_line_displays_confidence
    report = RailsAudit::Report.render(document_with([
      finding(category: "security", impact: "high", rule: "Mass Assignment", file: "app/models/user.rb",
              start_line: 12, confidence: "low", message: "boom")
    ]))

    assert_includes section(report, "Critical & High"),
                    "- `app/models/user.rb:12` **Mass Assignment** — boom (confidence: low)"
    refute_match(/^- `/m, section(report, "Security"))
  end

  def test_warnings_section_renders_after_tools_when_present
    document = document_with([], warnings: ["db/schema.rb not found — schema cops were inactive."])
    report = RailsAudit::Report.render(document)

    assert_includes report, "## Warnings\n- db/schema.rb not found — schema cops were inactive."
    assert_operator report.index("## Tools"), :<, report.index("## Warnings")
    assert_operator report.index("## Warnings"), :<, report.index("## Critical & High")
  end

  def test_warnings_section_is_omitted_entirely_when_there_are_none
    report = RailsAudit::Report.render(document_with([]))

    refute_includes report, "## Warnings"
  end

  def test_footer_includes_zero_impact_rows_and_distinct_confidences
    findings = [
      finding(category: "security", impact: "critical", rule: "SQLi", file: "a.rb", start_line: 1,
              confidence: "high"),
      finding(category: "style", impact: "info", rule: "Style/Foo", file: "b.rb", start_line: 1,
              confidence: "unreviewed")
    ]
    report = RailsAudit::Report.render(document_with(findings))

    assert_includes report, "| Critical | 1 |"
    assert_includes report, "| High | 0 |"
    assert_includes report, "| Medium | 0 |"
    assert_includes report, "| Low | 0 |"
    assert_includes report, "| Info | 1 |"
    assert_includes report, "| High | 1 |"
    assert_includes report, "| Unreviewed | 1 |"
  end

  private

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
    path = File.expand_path("../fixtures/raw/#{name}", __dir__)
    JSON.parse(File.read(path))
  end

  def finding(category:, impact:, rule:, file:, start_line:, confidence: "medium", message: "message")
    {
      id: "id",
      native_fingerprint: nil,
      tool: "rubocop",
      rule: rule,
      category: category,
      impact: impact,
      confidence: confidence,
      message: message,
      location: { file: file, start_line: start_line, end_line: start_line, column: nil, lines: nil },
      context: nil
    }
  end

  def rule_group(rule, count, impact: "info")
    count.times.map do |index|
      finding(category: "style", impact: impact, rule: rule, file: "app/models/foo.rb", start_line: index + 1)
    end
  end

  def document_with(findings, warnings: [])
    {
      target: "target/app",
      toolchain: { ruby: "4.0.1" },
      tools: [{ name: "rubocop", version: "1.88.2", raw_count: findings.size, exit_code: 1 }],
      warnings: warnings,
      findings: findings
    }
  end

  def section(report, heading)
    report[/^## #{Regexp.escape(heading)}\n.*?(?=^## |\z)/m]
  end

  def subgroup(leading, category)
    leading[/^#### #{Regexp.escape(category)} \(\d+\)\n.*?(?=^#### |^### |\z)/m]
  end
end
