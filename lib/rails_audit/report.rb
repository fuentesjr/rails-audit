# frozen_string_literal: true

module RailsAudit
  module Report
    CATEGORY_ORDER = %w[security correctness rails performance complexity design style].freeze
    IMPACT_ORDER = %w[critical high medium low info].freeze
    INDIVIDUAL_IMPACTS = %w[critical high].freeze
    INDIVIDUAL_CAP = 25
    AGGREGATE_TOP_N = 15
    # Not part of the v2 schema's confidence vocabulary (brakeman: high/medium/low) but kept
    # open-ended so an unrecognized value still renders deterministically instead of raising.
    CONFIDENCE_ORDER = %w[high medium low].freeze

    module_function

    def render(document)
      findings = document.fetch(:findings)
      blocks = [target_block(document), tools_block(document)]

      CATEGORY_ORDER.each do |category|
        category_findings = findings.select { |finding| finding.fetch(:category) == category }
        # v1 rendered empty categories with a "No findings." fallback (spike-reference.md §8);
        # skipping them entirely is simpler and loses no information the document doesn't already carry.
        next if category_findings.empty?

        blocks.concat(category_blocks(category, category_findings))
      end

      blocks << totals_by_impact_block(findings)
      blocks << totals_by_confidence_block(findings)

      "#{blocks.join("\n\n")}\n"
    end

    def target_block(document)
      "# rails-audit report\n\nTarget: #{document.fetch(:target)}"
    end
    private_class_method :target_block

    def tools_block(document)
      bullets = document.fetch(:tools).map do |tool|
        "- #{tool.fetch(:name)} #{tool.fetch(:version)} — #{tool.fetch(:raw_count)} findings " \
          "(exit #{tool.fetch(:exit_code)})"
      end
      "## Tools\n#{bullets.join("\n")}"
    end
    private_class_method :tools_block

    def category_blocks(category, findings)
      blocks = ["## #{category.capitalize}"]
      by_impact = findings.group_by { |finding| finding.fetch(:impact) }

      INDIVIDUAL_IMPACTS.each do |impact|
        group = by_impact[impact]
        blocks << individual_block(impact, group) if group && !group.empty?
      end

      aggregate_findings = findings.reject { |finding| INDIVIDUAL_IMPACTS.include?(finding.fetch(:impact)) }
      blocks << aggregate_block(aggregate_findings) unless aggregate_findings.empty?

      blocks
    end
    private_class_method :category_blocks

    def individual_block(impact, findings)
      lines = ["### #{impact.capitalize} (#{findings.size})"]
      findings.first(INDIVIDUAL_CAP).each do |finding|
        location = finding.fetch(:location)
        lines << "- `#{location.fetch(:file)}:#{location.fetch(:start_line)}` **#{finding.fetch(:rule)}** " \
          "— #{finding.fetch(:message)} (confidence: #{finding.fetch(:confidence)})"
      end
      lines << "- …and #{findings.size - INDIVIDUAL_CAP} more" if findings.size > INDIVIDUAL_CAP
      lines.join("\n")
    end
    private_class_method :individual_block

    def aggregate_block(findings)
      counts = findings.group_by { |finding| finding.fetch(:rule) }.transform_values(&:size)
      rows = counts.sort_by { |rule, count| [-count, rule] }.first(AGGREGATE_TOP_N)

      lines = [
        "### Medium / Low / Info (#{findings.size} total)",
        "",
        "| Rule | Count |",
        "| --- | --- |"
      ]
      rows.each { |rule, count| lines << "| #{rule} | #{count} |" }
      lines.join("\n")
    end
    private_class_method :aggregate_block

    def totals_by_impact_block(findings)
      counts = findings.group_by { |finding| finding.fetch(:impact) }.transform_values(&:size)
      lines = ["## Totals by impact", "", "| Impact | Count |", "| --- | --- |"]
      IMPACT_ORDER.each { |impact| lines << "| #{impact.capitalize} | #{counts.fetch(impact, 0)} |" }
      lines << "| **Total** | #{findings.size} |"
      lines.join("\n")
    end
    private_class_method :totals_by_impact_block

    def totals_by_confidence_block(findings)
      counts = findings.group_by { |finding| finding.fetch(:confidence) }.transform_values(&:size)
      ordered = CONFIDENCE_ORDER.select { |confidence| counts.key?(confidence) } +
                (counts.keys - CONFIDENCE_ORDER).sort

      lines = ["## Totals by confidence", "", "| Confidence | Count |", "| --- | --- |"]
      ordered.each { |confidence| lines << "| #{confidence.capitalize} | #{counts.fetch(confidence)} |" }
      lines << "| **Total** | #{findings.size} |"
      lines.join("\n")
    end
    private_class_method :totals_by_confidence_block
  end
end
