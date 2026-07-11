# frozen_string_literal: true

require "rubocop"

module RailsAudit
  module SchemaModel
    Column = Struct.new(:name, :type, :null, :line, :primary_key, keyword_init: true)
    Index = Struct.new(:columns, :unique, :name, :line, keyword_init: true)
    ForeignKey = Struct.new(
      :from, :to, :column, :primary_key, :line, keyword_init: true
    )
    Table = Struct.new(:name, :options, :line, :columns, :indices, keyword_init: true) do
      def primary_key?
        options[:id] != false || options.key?(:primary_key) || primary_key_column
      end

      def primary_key_name
        explicit_column = columns.find(&:primary_key)
        (explicit_column&.name || options.fetch(:primary_key, "id")).to_s
      end

      def primary_key_type
        primary_key_column&.type || options.fetch(:id, :bigint)
      end

      private

      def primary_key_column
        columns.find { |column| column.primary_key || column.name == primary_key_name }
      end
    end

    class Model
      attr_reader :tables, :foreign_keys

      def initialize(tables:, foreign_keys:)
        @tables = tables
        @foreign_keys = foreign_keys
      end

      def table(name)
        tables.find { |candidate| candidate.name == name }
      end
    end

    module_function

    def load(path)
      processed_source = RuboCop::ProcessedSource.new(File.read(path), RUBY_VERSION.to_f, path)
      errors = processed_source.diagnostics.select { |diagnostic| diagnostic.level == :error }
      if processed_source.ast.nil? || errors.any?
        details = errors.map(&:message).join("; ")
        raise RailsAudit::Error, "could not parse #{path}: #{details}"
      end

      build(processed_source.ast)
    end

    def build(ast)
      tables = ast.each_node(:block).filter_map { |node| build_table(node) }
      tables_by_name = tables.to_h { |table| [table.name, table] }

      ast.each_node(:send).each do |node|
        next unless node.method?(:add_index)

        table_name, index = build_add_index(node)
        tables_by_name.fetch(table_name).indices << index if tables_by_name.key?(table_name)
      end

      foreign_keys = ast.each_node(:send).filter_map do |node|
        build_foreign_key(node) if node.method?(:add_foreign_key)
      end
      Model.new(tables: tables, foreign_keys: foreign_keys)
    end
    private_class_method :build

    def build_table(node)
      send_node = node.send_node
      return unless send_node.method?(:create_table)

      variable = node.arguments.one? ? node.arguments.first.children.first : nil
      columns, indices = table_contents(node.body, variable).partition do |element|
        element.instance_of?(Column)
      end
      Table.new(
        name: literal(send_node.first_argument),
        options: options(send_node, 1),
        line: send_node.loc.expression.line,
        columns: columns,
        indices: indices
      )
    end
    private_class_method :build_table

    def table_contents(body, variable)
      statements(body).filter_map do |node|
        next unless node&.send_type?
        next unless node.receiver&.lvar_type? && node.receiver.children.first == variable

        if node.method?(:index)
          build_index(node, 0)
        else
          build_column(node)
        end
      end
    end
    private_class_method :table_contents

    def statements(body)
      return [] unless body

      body.begin_type? ? body.children : [body]
    end
    private_class_method :statements

    def build_column(node)
      column_options = options(node, 1)
      Column.new(
        name: literal(node.first_argument),
        type: column_type(node, column_options),
        null: column_options[:null],
        line: node.loc.expression.line,
        primary_key: node.method?(:primary_key)
      )
    end
    private_class_method :build_column

    def column_type(node, column_options)
      return node.method_name unless node.method?(:primary_key)

      column_options.fetch(:type, :bigint)
    end
    private_class_method :column_type

    def build_add_index(node)
      [literal(node.arguments.fetch(0)), build_index(node, 1)]
    end
    private_class_method :build_add_index

    def build_index(node, columns_position)
      index_options = options(node, columns_position + 1)
      columns = literal(node.arguments.fetch(columns_position))
      Index.new(
        columns: columns.is_a?(Array) ? columns : [columns],
        unique: index_options[:unique],
        name: index_options[:name],
        line: node.loc.expression.line
      )
    end
    private_class_method :build_index

    def build_foreign_key(node)
      foreign_key_options = options(node, 2)
      to = literal(node.arguments.fetch(1))
      ForeignKey.new(
        from: literal(node.arguments.fetch(0)),
        to: to,
        column: foreign_key_options.fetch(:column, "#{singularize(to)}_id"),
        primary_key: foreign_key_options.fetch(:primary_key, "id"),
        line: node.loc.expression.line
      )
    end
    private_class_method :build_foreign_key

    def options(node, first_option)
      hash = node.arguments.drop(first_option).find(&:hash_type?)
      return {} unless hash

      hash.pairs.to_h { |pair| [literal(pair.key), literal(pair.value)] }
    end
    private_class_method :options

    def literal(node)
      case node.type
      when :true then true
      when :false then false
      when :nil then nil
      when :array then node.values.map { |value| literal(value) }
      when :sym, :str, :int, :float then node.value
      # Non-scalar option values — e.g. the `default: -> { "gen_random_uuid()" }` the schema
      # dumper emits for Postgres function defaults — are not modeled, and no detector reads
      # them. Return nil rather than crash the whole audit calling #value on a block node.
      else nil
      end
    end
    private_class_method :literal

    def singularize(name)
      return "#{name.delete_suffix('ies')}y" if name.end_with?("ies")

      name.delete_suffix("s")
    end
    private_class_method :singularize
  end
end
