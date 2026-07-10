# frozen_string_literal: true

require "json"
require "test_helper"

class ReportTest < Minitest::Test
  TARGET_ROOT = "target/lobsters"

  def test_renders_realistic_document_from_fixtures
    document = fixture_document
    report = RailsAudit::Report.render(document)

    assert_includes report, "# rails-audit report"
    assert_includes report, "Target: #{TARGET_ROOT}"
    assert_includes report, "## Tools"
    assert_includes report, "- brakeman 8.0.5 — 27 findings (exit 3)"
    assert_includes report, "- rubocop 1.88.2 — 11176 findings (exit 1)"
    assert_includes report, "- reek 6.5.0 — 1700 findings (exit 2)"
    refute_includes report, "runtime_s"

    findings = document.fetch(:findings)
    by_category = findings.group_by { |finding| finding[:category] }

    RailsAudit::Report::CATEGORY_ORDER.each do |category|
      if by_category[category].to_a.empty?
        refute_includes report, "## #{category.capitalize}"
      else
        assert_includes report, "## #{category.capitalize}"
      end
    end

    security_critical = by_category.fetch("security").select { |finding| finding[:impact] == "critical" }
    refute_empty security_critical
    assert_includes report, "### Critical (#{security_critical.size})"
    first = security_critical.first
    location = first.fetch(:location)
    assert_includes report,
                     "- `#{location[:file]}:#{location[:start_line]}` **#{first[:rule]}** — " \
                     "#{first[:message]} (confidence: #{first[:confidence]})"

    assert_includes report, "### Medium / Low / Info"
    assert_includes report, "| Rule | Count |"

    assert_includes report, "## Totals by impact"
    assert_includes report, "## Totals by confidence"
    assert_includes report, "| **Total** | #{findings.size} |"
  end

  def test_individual_listing_caps_at_25_and_shows_overflow_marker
    findings = 30.times.map do |index|
      finding(category: "security", impact: "critical", rule: "SQL Injection",
               file: "app/models/story.rb", start_line: 100 + index)
    end
    report = RailsAudit::Report.render(document_with(findings))

    assert_includes report, "### Critical (30)"
    assert_includes report, "- …and 5 more"
    listing_lines = report.lines.select { |line| line.start_with?("- `app/models/story.rb:") }
    assert_equal 25, listing_lines.size
  end

  def test_aggregate_table_caps_at_top_n_sorted_by_count_desc_then_rule_asc
    findings = (1..14).flat_map { |count| rule_group(format("Rule%02d", count), count) }
    findings += rule_group("RuleZ", 20)
    findings += rule_group("RuleA", 20)
    findings += rule_group("Rule15", 19)

    report = RailsAudit::Report.render(document_with(findings))
    table_rows = report.lines.select { |line| line.start_with?("| Rule") && line != "| Rule | Count |\n" }

    assert_equal RailsAudit::Report::AGGREGATE_TOP_N, table_rows.size
    assert_equal "| RuleA | 20 |\n", table_rows[0]
    assert_equal "| RuleZ | 20 |\n", table_rows[1]
    assert_equal "| Rule15 | 19 |\n", table_rows[2]
    refute_includes report, "| Rule02 | 2 |"
    refute_includes report, "| Rule01 | 1 |"
  end

  def test_category_with_only_aggregate_findings_has_no_individual_subsection
    findings = [
      finding(category: "complexity", impact: "medium", rule: "Metrics/ClassLength", file: "app/models/x.rb",
               start_line: 1),
      finding(category: "complexity", impact: "low", rule: "Metrics/MethodLength", file: "app/models/x.rb",
               start_line: 2)
    ]
    report = RailsAudit::Report.render(document_with(findings))

    assert_includes report, "## Complexity"
    refute_includes report, "### Critical"
    refute_includes report, "### High"
    assert_includes report, "### Medium / Low / Info (2 total)"
  end

  def test_skips_categories_with_no_findings
    findings = [finding(category: "security", impact: "critical", rule: "SQL Injection", file: "a.rb", start_line: 1)]
    report = RailsAudit::Report.render(document_with(findings))

    (RailsAudit::Report::CATEGORY_ORDER - %w[security]).each do |category|
      refute_includes report, "## #{category.capitalize}"
    end
  end

  def test_individual_line_displays_confidence
    findings = [
      finding(category: "security", impact: "high", rule: "Mass Assignment", file: "app/models/user.rb",
               start_line: 12, confidence: "low", message: "boom")
    ]
    report = RailsAudit::Report.render(document_with(findings))

    assert_includes report, "- `app/models/user.rb:12` **Mass Assignment** — boom (confidence: low)"
  end

  def test_footer_totals_by_impact_and_confidence
    findings = [
      finding(category: "security", impact: "critical", rule: "SQLi", file: "a.rb", start_line: 1, confidence: "high"),
      finding(category: "security", impact: "critical", rule: "SQLi", file: "a.rb", start_line: 2, confidence: "high"),
      finding(category: "style", impact: "info", rule: "Style/Foo", file: "b.rb", start_line: 1, confidence: "medium"),
      finding(category: "style", impact: "info", rule: "Style/Foo", file: "b.rb", start_line: 2, confidence: "low")
    ]
    report = RailsAudit::Report.render(document_with(findings))

    assert_includes report, "| Critical | 2 |"
    assert_includes report, "| High | 0 |"
    assert_includes report, "| Medium | 0 |"
    assert_includes report, "| Low | 0 |"
    assert_includes report, "| Info | 2 |"

    assert_includes report, "| High | 2 |"
    assert_includes report, "| Medium | 1 |"
    assert_includes report, "| Low | 1 |"

    assert_equal 2, report.scan("| **Total** | 4 |").size
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

  # Hand-built finding hashes matching Finding#to_h's shape, bypassing the Finding class
  # since Report only reads a handful of fields — the document contract, not identity/hashing, is under test here.
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

  def rule_group(rule, count)
    count.times.map do |index|
      finding(category: "style", impact: "info", rule: rule, file: "app/models/foo.rb", start_line: index + 1)
    end
  end

  def document_with(findings)
    {
      target: "target/app",
      toolchain: { ruby: "4.0.1" },
      tools: [{ name: "rubocop", version: "1.88.2", raw_count: findings.size, exit_code: 1 }],
      findings: findings
    }
  end
end
