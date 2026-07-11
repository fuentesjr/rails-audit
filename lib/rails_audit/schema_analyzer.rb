# frozen_string_literal: true

require "fileutils"
require "json"

module RailsAudit
  module SchemaAnalyzer
    module_function

    def analyze(target:, output_path:)
      schema_path = File.join(target, "db", "schema.rb")
      return result(payload: [], output_path: output_path) unless File.exist?(schema_path)

      model = SchemaModel.load(schema_path)
      payload = detectors.flat_map { |detector| send(detector, model) }
        .sort_by { |finding| [finding.fetch("line"), finding.fetch("rule"), finding.fetch("discriminator")] }
      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(output_path, JSON.pretty_generate(payload))
      result(payload: payload, output_path: output_path)
    end

    def detectors
      %i[
        tables_without_primary_keys mismatched_foreign_key_types unindexed_foreign_keys
        extraneous_indices short_primary_key_types
      ]
    end
    private_class_method :detectors

    def tables_without_primary_keys(model)
      model.tables.filter_map do |table|
        next unless table.options[:id] == false
        next if table.primary_key?

        finding(
          rule: "Schema/TableWithoutPrimaryKey",
          message: "Table #{table.name} has no primary key.",
          line: table.line,
          discriminator: "#{table.name}.primary_key"
        )
      end
    end
    private_class_method :tables_without_primary_keys

    def mismatched_foreign_key_types(model)
      explicit = model.foreign_keys.filter_map do |foreign_key|
        from = model.table(foreign_key.from)
        to = model.table(foreign_key.to)
        column = from&.columns&.find { |candidate| candidate.name == foreign_key.column }
        next unless from && to && column
        next if polymorphic?(from, column)

        target_type = primary_key_type(to, foreign_key.primary_key)
        next unless target_type
        next if comparable_type(column.type) == comparable_type(target_type)

        finding(
          rule: "Schema/MismatchedForeignKeyType",
          message: "Foreign key #{from.name}.#{column.name} is #{column.type}, but " \
                   "#{to.name}.#{foreign_key.primary_key} is #{target_type}.",
          line: column.line,
          discriminator: "#{from.name}.#{column.name}"
        )
      end

      explicit_columns = model.foreign_keys.to_h do |foreign_key|
        [[foreign_key.from, foreign_key.column], true]
      end
      explicit + model.tables.flat_map do |table|
        table.columns.filter_map do |column|
          next unless column.name.end_with?("_id")
          next if explicit_columns[[table.name, column.name]]
          next if polymorphic?(table, column)

          referenced = inferred_table(model, column.name.delete_suffix("_id"))
          next unless referenced

          target_type = primary_key_type(referenced, "id")
          # A referenced table with a non-`id`, absent, or unmodeled primary key yields no
          # comparable type — skip rather than compare against nil/false (mirrors the explicit
          # branch's guard above; without it comparable_type(nil) crashes the whole audit).
          next unless target_type
          next if comparable_type(column.type) == comparable_type(target_type)

          finding(
            rule: "Schema/MismatchedForeignKeyType",
            message: "Inferred foreign key #{table.name}.#{column.name} is #{column.type}, " \
                     "but #{referenced.name}.id is #{target_type}.",
            line: column.line,
            discriminator: "#{table.name}.#{column.name}",
            confidence: "medium"
          )
        end
      end
    end
    private_class_method :mismatched_foreign_key_types

    def unindexed_foreign_keys(model)
      explicit_columns = model.foreign_keys.to_h do |foreign_key|
        [[foreign_key.from, foreign_key.column], true]
      end

      model.tables.flat_map do |table|
        table.columns.filter_map do |column|
          next unless column.name.end_with?("_id")

          type_column = column.name.sub(/_id\z/, "_type")
          indexed = if table.columns.any? { |candidate| candidate.name == type_column }
                      table.indices.any? { |index| index.columns.first(2) == [type_column, column.name] }
                    else
                      table.indices.any? { |index| index.columns.first == column.name }
                    end
          next if indexed

          finding(
            rule: "Schema/UnindexedForeignKey",
            message: "Foreign key #{table.name}.#{column.name} has no leading-column index.",
            line: column.line,
            discriminator: "#{table.name}.#{column.name}",
            confidence: explicit_columns[[table.name, column.name]] ? "high" : "medium"
          )
        end
      end
    end
    private_class_method :unindexed_foreign_keys

    def extraneous_indices(model)
      model.tables.flat_map do |table|
        primary_key = primary_key_name(table)
        duplicates = droppable_duplicate_indices(table.indices)
        table.indices.filter_map do |index|
          next unless duplicates.any? { |dup| dup.equal?(index) } ||
                      prefix_redundant?(index, table.indices) ||
                      (index.columns.one? && index.columns.first == primary_key)

          finding(
            rule: "Schema/ExtraneousIndex",
            message: "Index #{index.name || index.columns.join(', ')} on #{table.name} is redundant.",
            line: index.line,
            discriminator: "#{table.name}.#{index.name || index.columns.join(',')}"
          )
        end
      end
    end
    private_class_method :extraneous_indices

    # A unique index is never made redundant by a longer index sharing its prefix: dropping it
    # would drop the uniqueness constraint the longer index does not carry.
    def prefix_redundant?(index, indices)
      return false if index.unique

      indices.any? do |other|
        index != other && index.columns.length < other.columns.length &&
          other.columns.first(index.columns.length) == index.columns
      end
    end
    private_class_method :prefix_redundant?

    # Indexes on identical column lists are exact duplicates; keep one (preferring a unique
    # index, then the earliest by name/line) and report the rest as droppable.
    def droppable_duplicate_indices(indices)
      indices.group_by(&:columns).flat_map do |_columns, group|
        next [] if group.one?

        keeper = group.min_by { |index| [index.unique ? 0 : 1, index.name.to_s, index.line] }
        group.reject { |index| index.equal?(keeper) }
      end
    end
    private_class_method :droppable_duplicate_indices

    def short_primary_key_types(model)
      model.tables.filter_map do |table|
        next unless %i[integer serial].include?(table.options[:id])

        finding(
          rule: "Schema/ShortPrimaryKeyType",
          message: "Table #{table.name} uses the narrow #{table.options[:id]} primary key type.",
          line: table.line,
          discriminator: "#{table.name}.primary_key"
        )
      end
    end
    private_class_method :short_primary_key_types

    def primary_key_name(table)
      table.primary_key_name
    end
    private_class_method :primary_key_name

    def primary_key_type(table, primary_key)
      return unless primary_key.to_s == table.primary_key_name
      return unless table.primary_key?

      table.primary_key_type
    end
    private_class_method :primary_key_type

    def comparable_type(type)
      { serial: :integer, bigserial: :bigint }.fetch(type.to_sym, type.to_sym)
    end
    private_class_method :comparable_type

    def inferred_table(model, singular_name)
      model.table(singular_name) || model.table("#{singular_name}s") ||
        model.table(singular_name.sub(/y\z/, "ies"))
    end
    private_class_method :inferred_table

    def polymorphic?(table, column)
      type_column = column.name.sub(/_id\z/, "_type")
      table.columns.any? { |candidate| candidate.name == type_column }
    end
    private_class_method :polymorphic?

    def finding(rule:, message:, line:, discriminator:, confidence: "high")
      {
        "rule" => rule,
        "message" => message,
        "line" => line,
        "discriminator" => discriminator,
        "confidence" => confidence
      }
    end
    private_class_method :finding

    def result(payload:, output_path:)
      {
        name: "schema",
        version: RailsAudit::VERSION,
        raw_count: payload.size,
        exit_code: 0,
        payload: payload,
        output_path: output_path
      }
    end
    private_class_method :result
  end
end
