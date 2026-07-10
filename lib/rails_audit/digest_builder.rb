# frozen_string_literal: true

module RailsAudit
  module DigestBuilder
    HARD_CAP = 15_000
    INDIVIDUAL_BUDGET = 9_000
    AGGREGATE_TOP_N = 40
    INDIVIDUAL_IMPACTS = %w[critical high].freeze
    IMPACT_ORDER = %w[critical high medium low info].freeze

    module_function

    def build(document)
      findings = value(document, :findings)
      digest = [
        stats_block(document, findings),
        individual_block(findings),
        aggregate_block(findings)
      ].join("\n\n") << "\n"

      hard_cap(digest)
    end

    def stats_block(document, findings)
      impact_counts = findings.group_by { |finding| value(finding, :impact) }.transform_values(&:size)
      impact_lines = IMPACT_ORDER.map { |impact| "- #{impact}: #{impact_counts.fetch(impact, 0)}" }
      tool_lines = value(document, :tools).map do |tool|
        "- #{value(tool, :name)}: #{value(tool, :raw_count)} raw findings"
      end

      [
        "# rails-audit LLM digest",
        "Target: #{value(document, :target)}",
        "",
        "## Overall stats",
        "Total findings: #{findings.size}",
        "",
        "### By impact",
        *impact_lines,
        "",
        "### Raw counts by tool",
        *tool_lines
      ].join("\n")
    end
    private_class_method :stats_block

    def individual_block(findings)
      individual = canonical_findings(findings.select do |finding|
        INDIVIDUAL_IMPACTS.include?(value(finding, :impact))
      end)
      lines = individual.map { |finding| individual_line(finding) }
      heading = "## Critical & High findings"
      return "#{heading}\nNone." if lines.empty?

      individual.size.downto(0) do |visible_count|
        dropped = individual.drop(visible_count)
        marker = truncation_marker(
          dropped: dropped,
          total: individual.size,
          label: "critical/high findings"
        )
        block = ([heading] + lines.first(visible_count) + Array(marker)).join("\n")
        return block if block.length <= INDIVIDUAL_BUDGET
      end

      ([heading, truncation_marker(dropped: individual, total: individual.size,
                                   label: "critical/high findings")]).join("\n")
    end
    private_class_method :individual_block

    def individual_line(finding)
      location = value(finding, :location)
      "- [#{value(finding, :impact)}/#{value(finding, :category)}/#{value(finding, :tool)}] " \
        "#{value(location, :file)}:#{value(location, :start_line)} #{value(finding, :rule)} — " \
        "#{value(finding, :message)} (confidence: #{value(finding, :confidence)})"
    end
    private_class_method :individual_line

    def aggregate_block(findings)
      aggregate_findings = findings.reject do |finding|
        INDIVIDUAL_IMPACTS.include?(value(finding, :impact))
      end
      rows = aggregate_findings.group_by do |finding|
        [value(finding, :category), value(finding, :impact), value(finding, :tool), value(finding, :rule)]
      end.map { |key, group| [key, group.size] }
      rows.sort_by! { |(category, impact, tool, rule), count| [-count, category, impact, tool, rule] }

      lines = [
        "## Medium, Low & Info aggregates",
        "| Category | Impact | Tool | Rule | Count |",
        "| --- | --- | --- | --- | --- |"
      ]
      rows.first(AGGREGATE_TOP_N).each do |(category, impact, tool, rule), count|
        lines << "| #{category} | #{impact} | #{tool} | #{rule} | #{count} |"
      end

      dropped_rows = rows.drop(AGGREGATE_TOP_N)
      if dropped_rows.any?
        dropped_count = dropped_rows.sum { |(_key, count)| count }
        breakdown = rule_breakdown_from_rows(dropped_rows)
        lines << "- [TRUNCATED: #{dropped_rows.size} of #{rows.size} aggregate rows dropped " \
                 "(#{dropped_count} findings). Rule counts: #{format_breakdown(breakdown)}]"
      end
      lines.join("\n")
    end
    private_class_method :aggregate_block

    def canonical_findings(findings)
      findings.sort_by do |finding|
        location = value(finding, :location)
        [
          IMPACT_ORDER.index(value(finding, :impact)) || IMPACT_ORDER.size,
          value(finding, :category), value(location, :file), value(location, :start_line),
          value(finding, :tool), value(finding, :rule), value(finding, :message), value(finding, :id)
        ]
      end
    end
    private_class_method :canonical_findings

    def truncation_marker(dropped:, total:, label:)
      return if dropped.empty?

      breakdown = dropped.group_by { |finding| value(finding, :rule) }.transform_values(&:size)
      "- [TRUNCATED: #{dropped.size} of #{total} #{label} dropped. " \
        "Rule counts: #{format_breakdown(breakdown)}]"
    end
    private_class_method :truncation_marker

    def rule_breakdown_from_rows(rows)
      rows.each_with_object(Hash.new(0)) do |((_, _, _, rule), count), counts|
        counts[rule] += count
      end
    end
    private_class_method :rule_breakdown_from_rows

    def format_breakdown(counts)
      counts.sort.map { |rule, count| "#{rule}=#{count}" }.join("; ")
    end
    private_class_method :format_breakdown

    def hard_cap(digest)
      return digest if digest.length <= HARD_CAP

      marker = ""
      loop do
        kept = HARD_CAP - marker.length
        dropped = digest.length - kept
        replacement = "[FINAL HARD-CAP BACKSTOP: #{dropped} of #{digest.length} characters dropped]"
        break marker = replacement if replacement == marker

        marker = replacement
      end

      digest.slice(0, HARD_CAP - marker.length) + marker
    end
    private_class_method :hard_cap

    def value(hash, key)
      return hash.fetch(key) if hash.key?(key)

      hash.fetch(key.to_s)
    end
    private_class_method :value
  end
end
