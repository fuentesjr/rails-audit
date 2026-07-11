# frozen_string_literal: true

module RailsAudit
  module Normalizer
    # RuboCop and Reek emit no native fingerprint; nil keeps that field's meaning distinct from id.
    module_function

    def brakeman(payload, target_root:)
      payload.fetch("warnings").map do |warning|
        raw_context = warning["location"] || {}
        context = if raw_context["class"] || raw_context["method"]
                    { class: raw_context["class"], method: raw_context["method"] }
                  end
        file = relative_path(warning.fetch("file"), target_root)
        line = warning.fetch("line")
        rule = warning.fetch("warning_type")

        Finding.new(
          native_fingerprint: warning.fetch("fingerprint"),
          tool: "brakeman",
          rule: rule,
          category: Mappings.category(tool: "brakeman", rule: rule),
          impact: Mappings.impact(tool: "brakeman", rule: rule),
          confidence: Mappings.confidence(
            tool: "brakeman",
            raw_confidence: warning["confidence"]
          ),
          message: warning.fetch("message"),
          location: location(file: file, start_line: line, end_line: line),
          context: context
        )
      end
    end

    def rubocop(payload, target_root:)
      payload.fetch("files").flat_map do |raw_file|
        file = relative_path(raw_file.fetch("path"), target_root)

        raw_file.fetch("offenses").map do |offense|
          raw_location = offense.fetch("location")
          rule = offense.fetch("cop_name")

          Finding.new(
            native_fingerprint: nil,
            tool: "rubocop",
            rule: rule,
            category: Mappings.category(tool: "rubocop", rule: rule),
            impact: Mappings.impact(tool: "rubocop", rule: rule),
            confidence: Mappings.confidence(tool: "rubocop"),
            message: offense.fetch("message"),
            location: location(
              file: file,
              start_line: raw_location.fetch("start_line"),
              end_line: raw_location.fetch("last_line"),
              column: raw_location.fetch("start_column")
            )
          )
        end
      end
    end

    def reek(payload, target_root:)
      payload.map do |smell|
        raw_lines = smell.fetch("lines")
        sorted_lines = raw_lines.sort
        rule = smell.fetch("smell_type")

        Finding.new(
          native_fingerprint: nil,
          tool: "reek",
          rule: rule,
          category: Mappings.category(tool: "reek", rule: rule),
          impact: Mappings.impact(tool: "reek", rule: rule),
          confidence: Mappings.confidence(tool: "reek"),
          message: smell.fetch("message"),
          discriminator: smell["name"].to_s,
          location: location(
            file: relative_path(smell.fetch("source"), target_root),
            start_line: sorted_lines.min,
            end_line: sorted_lines.max,
            lines: sorted_lines.size > 2 ? sorted_lines : nil
          )
        )
      end
    end

    def schema(payload, target_root:)
      payload.map do |raw_finding|
        rule = raw_finding.fetch("rule")
        line = raw_finding.fetch("line")

        Finding.new(
          native_fingerprint: nil,
          tool: "schema",
          rule: rule,
          category: Mappings.category(tool: "schema", rule: rule),
          impact: Mappings.impact(tool: "schema", rule: rule),
          confidence: Mappings.confidence(
            tool: "schema", raw_confidence: raw_finding.fetch("confidence")
          ),
          message: raw_finding.fetch("message"),
          discriminator: raw_finding.fetch("discriminator"),
          location: location(
            file: relative_path(File.join(target_root, "db", "schema.rb"), target_root),
            start_line: line,
            end_line: line
          )
        )
      end
    end

    def normalize(brakeman:, rubocop:, reek:, schema:, target_root:)
      ensure_unique_ids(canonical_sort(
        self.brakeman(brakeman, target_root: target_root) +
          self.rubocop(rubocop, target_root: target_root) +
          self.reek(reek, target_root: target_root) +
          self.schema(schema, target_root: target_root)
      ))
    end

    def canonical_sort(findings)
      findings.sort_by do |finding|
        [finding.location.fetch(:file), finding.location.fetch(:start_line), finding.tool, finding.rule]
      end
    end

    def document(target:, toolchain:, tools:, findings:, warnings: [])
      {
        target: target,
        toolchain: toolchain,
        tools: tools.map { |tool| tool.reject { |key, _value| key.to_s == "runtime_s" } },
        warnings: warnings,
        findings: canonical_sort(findings).map(&:to_h)
      }
    end

    def relative_path(path, target_root)
      path.delete_prefix("#{target_root.delete_suffix("/")}/")
    end
    private_class_method :relative_path

    def location(file:, start_line:, end_line:, column: nil, lines: nil)
      { file: file, start_line: start_line, end_line: end_line, column: column, lines: lines }
    end
    private_class_method :location

    def ensure_unique_ids(findings)
      groups = findings.each_index.group_by { |index| findings[index].id }
      used_ids = groups.filter_map { |id, indexes| id if indexes.one? }.to_h { |id| [id, true] }

      groups.each_value do |indexes|
        next if indexes.one?

        ordinal = 1
        indexes.sort_by { |index| [findings[index].message, index] }.each do |index|
          finding = findings[index]

          loop do
            # Ordinal identities can shift when membership of a collision group changes.
            replacement = reidentify(finding, "#{finding.discriminator}|#{ordinal}")
            ordinal += 1
            next if used_ids[replacement.id]

            findings[index] = replacement
            used_ids[replacement.id] = true
            break
          end
        end
      end

      findings
    end
    private_class_method :ensure_unique_ids

    def reidentify(finding, discriminator)
      Finding.new(
        native_fingerprint: finding.native_fingerprint,
        tool: finding.tool,
        rule: finding.rule,
        category: finding.category,
        impact: finding.impact,
        confidence: finding.confidence,
        message: finding.message,
        location: finding.location,
        context: finding.context,
        discriminator: discriminator
      )
    end
    private_class_method :reidentify
  end
end
