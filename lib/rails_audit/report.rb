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
      warnings = document.fetch(:warnings, [])
      blocks << warnings_block(warnings) unless warnings.empty?
      blocks << critical_and_high_block(findings)

      ordered_categories(findings).each do |category|
        category_findings = findings.select { |finding| finding.fetch(:category) == category }
        blocks << category_block(category, category_findings)
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

    def warnings_block(warnings)
      # A reader must never mistake a quiet audit for a clean one; surface tool-inactivity
      # (e.g. schema-dependent cops with no db/schema.rb) as loudly as findings themselves.
      lines = ["## Warnings"] + warnings.map { |warning| "- #{warning}" }
      lines.join("\n")
    end
    private_class_method :warnings_block

    def critical_and_high_block(findings)
      individual_findings = findings.select do |finding|
        INDIVIDUAL_IMPACTS.include?(finding.fetch(:impact))
      end
      return "## Critical & High\n\nNone." if individual_findings.empty?

      lines = ["## Critical & High"]
      INDIVIDUAL_IMPACTS.each do |impact|
        impact_findings = individual_findings.select { |finding| finding.fetch(:impact) == impact }
        next if impact_findings.empty?

        lines << ""
        lines << "### #{impact.capitalize}"
        ordered_categories(impact_findings).each do |category|
          subgroup = impact_findings.select { |finding| finding.fetch(:category) == category }
          lines << ""
          lines.concat(individual_subgroup_lines(category, subgroup))
        end
      end
      lines.join("\n")
    end
    private_class_method :critical_and_high_block

    def individual_subgroup_lines(category, findings)
      lines = ["#### #{category} (#{findings.size})"]
      findings.first(INDIVIDUAL_CAP).each do |finding|
        location = finding.fetch(:location)
        lines << "- `#{location.fetch(:file)}:#{location.fetch(:start_line)}` **#{finding.fetch(:rule)}** " \
          "— #{finding.fetch(:message)} (confidence: #{finding.fetch(:confidence)})"
      end
      lines << "- …and #{findings.size - INDIVIDUAL_CAP} more" if findings.size > INDIVIDUAL_CAP
      lines
    end
    private_class_method :individual_subgroup_lines

    def category_block(category, findings)
      individual_count = findings.count do |finding|
        INDIVIDUAL_IMPACTS.include?(finding.fetch(:impact))
      end
      reference = "Critical/High: #{individual_count}."
      if individual_count.positive?
        reference = "Critical/High: #{individual_count} — listed individually in the Critical & High section above."
      end

      ["## #{category.capitalize}", reference, aggregate_table(findings), "Total: #{findings.size} findings."].join("\n\n")
    end
    private_class_method :category_block

    def aggregate_table(findings)
      groups = findings.group_by do |finding|
        [finding.fetch(:impact), finding.fetch(:tool), finding.fetch(:rule)]
      end
      groups = groups.map { |key, group| [key, group.size] }
      groups.sort_by! do |(impact, tool, rule), count|
        [impact_rank(impact), -count, rule, tool]
      end
      visible_groups = groups.first(AGGREGATE_TOP_N)

      lines = [
        "| Impact | Rule | Count |",
        "| --- | --- | --- |"
      ]
      visible_groups.each do |(impact, _tool, rule), count|
        lines << "| #{impact.capitalize} | #{rule} | #{count} |"
      end

      dropped_groups = groups.drop(AGGREGATE_TOP_N)
      if dropped_groups.any?
        dropped_findings = dropped_groups.sum { |_key, count| count }
        lines << "- …and #{dropped_groups.size} more rules (#{dropped_findings} findings)"
      end
      lines.join("\n")
    end
    private_class_method :aggregate_table

    def ordered_categories(findings)
      present = findings.map { |finding| finding.fetch(:category) }.uniq
      CATEGORY_ORDER.select { |category| present.include?(category) } + (present - CATEGORY_ORDER).sort
    end
    private_class_method :ordered_categories

    def impact_rank(impact)
      IMPACT_ORDER.index(impact) || IMPACT_ORDER.size
    end
    private_class_method :impact_rank

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
