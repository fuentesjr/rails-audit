# frozen_string_literal: true

module RailsAudit
  module Execution
    class UnexpectedActiveRecordDoctorOutputError < RailsAudit::Error
      attr_reader :raw_output

      def initialize(message, raw_output:)
        @raw_output = raw_output
        super("#{message}\nRaw active_record_doctor output:\n#{raw_output}")
      end
    end

    class ActiveRecordDoctorParser
      DETECTORS = %i[
        missing_presence_validation missing_foreign_keys missing_unique_indexes
        incorrect_boolean_presence_validation incorrect_length_validation extraneous_indexes
        unindexed_deleted_at undefined_table_references missing_non_null_constraint
        unindexed_foreign_keys incorrect_dependent_option short_primary_key_type
        mismatched_foreign_key_type table_without_primary_key table_without_timestamps
      ].freeze
      BEGIN_REPORT = "RAILS_AUDIT_ACTIVE_RECORD_DOCTOR_BEGIN 1"
      END_REPORT = "RAILS_AUDIT_ACTIVE_RECORD_DOCTOR_END"
      BEGIN_DETECTOR = /\ARAILS_AUDIT_DETECTOR_BEGIN ([a-z_]+)\z/
      END_DETECTOR = /\ARAILS_AUDIT_DETECTOR_END ([a-z_]+) (clean|findings|error)\z/

      MESSAGE_PATTERNS = {
        missing_presence_validation: /\Aadd a `presence` validator to (?<model>[\w:]+)\.(?<column>\w+) - it's NOT NULL but lacks a validator\z/,
        missing_foreign_keys: /\Acreate a foreign key on (?<table>\w+)\.(?<column>\w+) - looks like an association without a foreign key constraint\z/,
        missing_unique_indexes: /\Aadd a unique(?: expression)? index on (?<table>\w+)\((?<columns>[\w, ]+)\) - (?:validating(?: case-insensitive)? uniqueness|using `has_one`|using `has_and_belongs_to_many`) in [\w:]+ without an?(?: expression)? index can lead to duplicates(?: \(a regular unique index is not enough\))?\z/,
        incorrect_boolean_presence_validation: /\Areplace the `presence` validator on (?<model>[\w:]+)\.(?<column>\w+) with `inclusion` - `presence` can't be used on booleans\z/,
        incorrect_length_validation: /\A(?:the schema limits (?<table>\w+)\.(?<column>\w+)|the length validator on (?<model>[\w:]+)\.(?<attribute>\w+)).+ - (?:set both limits to the same value or remove both|remove the database limit or add the validator|remove the validator or the schema length limit)\z/,
        extraneous_indexes: /\Aremove (?:the index )?(?<index>\S+) from (?:the table )?(?<table>\w+) - (?:coincides with the primary key on the table|queries should be able to use the following .+ instead: .+)\z/,
        unindexed_deleted_at: /\Aconsider adding `WHERE (?<column>\w+) IS NULL` or `WHERE \k<column> IS NOT NULL` to (?<index>\S+) - a partial index can speed lookups of soft-deletable models\z/,
        undefined_table_references: /\A(?<model>[\w:]+) references a non-existent table or view named (?<table>\w+)\z/,
        missing_non_null_constraint: /\Aadd `NOT NULL` to (?<table>\w+)\.(?<column>\w+) - models validates its presence but it's not non-NULL in the database\z/,
        unindexed_foreign_keys: /\Aadd an index on (?<table>\w+)\((?<columns>[\w, ]+)\) - foreign keys are often used in database lookups and should be indexed for performance reasons\z/,
        incorrect_dependent_option: /\A(?:ensure|don't use|use) .+ on (?<model>[\w:]+)\.(?<association>\w+) .+\z/,
        short_primary_key_type: /\Achange the type of (?<table>\w+)\.(?<column>\w+) to bigint\z/,
        mismatched_foreign_key_type: /\A(?<table>\w+)\.(?<column>\w+) is a foreign key of type \w+ and references \w+\.\w+ of type \w+ - foreign keys should be of the same type as the referenced column\z/,
        table_without_primary_key: /\Aadd a primary key to (?<table>\w+)\z/,
        table_without_timestamps: /\Aadd a (?:created_at|updated_at) column to (?<table>\w+)\z/
      }.freeze

      def parse(raw_output, diagnostic_output: raw_output)
        lines = raw_output.lines(chomp: true)
        report_start = lines.index(BEGIN_REPORT)
        malformed!("missing report start marker", diagnostic_output) unless report_start

        cursor = report_start + 1
        sections = {}
        until lines[cursor] == END_REPORT
          begin_match = BEGIN_DETECTOR.match(lines.fetch(cursor, ""))
          malformed!("expected detector start marker", diagnostic_output) unless begin_match
          detector = begin_match[1].to_sym
          malformed!("duplicate detector #{detector}", diagnostic_output) if sections.key?(detector)
          cursor += 1

          messages = []
          until lines[cursor].nil? || END_DETECTOR.match?(lines[cursor])
            messages << lines[cursor]
            cursor += 1
          end
          end_match = END_DETECTOR.match(lines.fetch(cursor, ""))
          malformed!("missing detector end marker for #{detector}", diagnostic_output) unless end_match
          unless end_match[1] == detector.to_s
            malformed!("mismatched detector end marker for #{detector}", diagnostic_output)
          end
          validate_status!(detector, end_match[2], messages, diagnostic_output)
          sections[detector] = messages
          cursor += 1
        end

        unless sections.keys.sort == DETECTORS.sort
          malformed!("unexpected detector set #{sections.keys.inspect}", diagnostic_output)
        end
        if lines.drop(cursor + 1).any? { |line| !line.empty? }
          malformed!("unexpected output after report end", diagnostic_output)
        end

        sections.flat_map do |detector, messages|
          messages.map { |message| finding(detector, message, diagnostic_output) }
        end
      rescue IndexError
        malformed!("truncated report", diagnostic_output)
      end

      private

      def validate_status!(detector, status, messages, raw_output)
        valid = (status == "clean" && messages.empty?) || (status == "findings" && messages.any?)
        malformed!("detector #{detector} reported #{status}", raw_output) unless valid
      end

      def finding(detector, message, raw_output)
        match = MESSAGE_PATTERNS.fetch(detector).match(message)
        malformed!("unexpected #{detector} finding line", raw_output) unless match
        subject = subject_for(match)

        Finding.new(
          native_fingerprint: nil,
          tool: "active_record_doctor",
          rule: detector.to_s,
          category: Mappings.category(tool: "active_record_doctor", rule: detector.to_s),
          impact: Mappings.impact(tool: "active_record_doctor", rule: detector.to_s),
          confidence: Mappings.confidence(tool: "active_record_doctor", rule: detector.to_s),
          message: message,
          location: { file: "db/schema.rb", start_line: 1, end_line: 1, column: nil, lines: nil },
          context: { subject: subject },
          discriminator: "#{subject}|#{message}"
        )
      end

      def subject_for(match)
        captures = match.named_captures
        table = captures["table"]
        columns = captures["columns"]
        return columns.split(", ").map { |column| "#{table}.#{column}" }.join(",") if table && columns
        return "#{table}.#{captures['column']}" if table && captures["column"]
        return table if table

        model = captures["model"]
        attribute = captures["column"] || captures["attribute"] || captures["association"]
        return "#{model}.#{attribute}" if model && attribute

        captures["index"]
      end

      def malformed!(message, raw_output)
        raise UnexpectedActiveRecordDoctorOutputError.new(message, raw_output: raw_output)
      end
    end
  end
end
