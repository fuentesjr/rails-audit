# frozen_string_literal: true

require "fileutils"
require "json"
require "psych"

module RailsAudit
  module ResilienceAnalyzer
    DATABASE_FILE = "config/database.yml"
    LOCKFILE = "Gemfile.lock"
    POSTGRES_ADAPTERS = %w[postgresql postgis].freeze
    MYSQL_ADAPTERS = %w[mysql2 trilogy].freeze
    SQLITE_ADAPTER = "sqlite3"
    REQUEST_TIMEOUT_GEMS = %w[rack-timeout slowpoke].freeze
    private_constant :DATABASE_FILE, :LOCKFILE, :POSTGRES_ADAPTERS, :MYSQL_ADAPTERS,
                     :SQLITE_ADAPTER, :REQUEST_TIMEOUT_GEMS

    class DatabaseParseError < StandardError; end
    private_constant :DatabaseParseError

    module_function

    def analyze(target:, output_path:)
      database_payload, database_warnings = analyze_database(target)
      lockfile_payload, lockfile_warnings = analyze_lockfile(target)
      payload = (database_payload + lockfile_payload).sort_by do |row|
        [row.fetch("file"), row.fetch("line"), row.fetch("rule"), row.fetch("discriminator")]
      end

      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(output_path, JSON.pretty_generate(payload))
      result(payload: payload, output_path: output_path, warnings: database_warnings + lockfile_warnings)
    end

    def analyze_database(target)
      path = File.join(target, DATABASE_FILE)
      return [[], [missing_database_warning]] unless File.exist?(path)

      source = File.read(path)
      if source.match?(/^\s*<%/)
        return [[], [unparseable_database_warning("ERB beyond value positions")]]
      end

      document = Psych.parse(source, filename: path)
      root = document&.root
      return [[], [unparseable_database_warning("invalid YAML document shape")]] unless mapping?(root)

      anchors = collect_anchors(root)
      entries, warnings = production_entries(root, anchors)
      findings = []
      entries.each do |entry|
        begin
          entry_findings, entry_warnings = analyze_database_entry(entry, anchors)
          findings.concat(entry_findings)
          warnings.concat(entry_warnings)
        rescue DatabaseParseError => e
          warnings << entry_alias_warning(entry.fetch(:path), e)
        end
      end
      [findings, warnings]
    rescue Psych::SyntaxError => e
      [[], [unparseable_database_warning("invalid YAML: #{e.problem}")]]
    rescue DatabaseParseError => e
      [[], [unparseable_database_warning(e.message)]]
    end
    private_class_method :analyze_database

    def analyze_lockfile(target)
      path = File.join(target, LOCKFILE)
      return [[], [missing_lockfile_warning]] unless File.exist?(path)
      return [[], []] if request_timeout_gem?(File.read(path))

      [[finding(
        rule: "Resilience/MissingRequestTimeout",
        message: "Gemfile.lock contains neither rack-timeout nor slowpoke; application requests " \
                 "can run without a service timeout. Suggested: add and configure rack-timeout " \
                 "(or slowpoke).",
        file: LOCKFILE,
        line: 1,
        discriminator: "request-timeout",
        confidence: "high"
      )], []]
    end
    private_class_method :analyze_lockfile

    def request_timeout_gem?(source)
      names = REQUEST_TIMEOUT_GEMS.map { |name| Regexp.escape(name) }.join("|")
      source.match?(/^    (?:#{names}) \([^)]+\)\r?$/)
    end
    private_class_method :request_timeout_gem?

    def production_entries(root, anchors)
      production = mapping_entries(root, anchors).fetch("production", nil)
      return [[], [production_not_defined_warning]] unless production

      production_node = dereference(production.fetch(:value), anchors)
      return [[], [production_not_defined_warning]] if null_scalar?(production_node)

      unless mapping?(production_node)
        raw_value = scalar_value(production_node, anchors)
        reason = raw_value&.include?("<%") ? "ERB beyond value positions" :
          "invalid YAML document shape"
        raise DatabaseParseError, reason
      end

      production_mapping = mapping_entries(production_node, anchors)
      if production_mapping.key?("adapter")
        entry = database_entry("production", production_mapping, node_line(production.fetch(:key)))
        return [[entry], []]
      end

      entries = []
      warnings = []
      mapping_child = false
      production_mapping.each do |name, nested|
        path = "production.#{name}"
        begin
          nested_node = dereference(nested.fetch(:value), anchors)
          next unless mapping?(nested_node)

          mapping_child = true
          nested_mapping = mapping_entries(nested_node, anchors)
          if nested_mapping.key?("adapter")
            entries << database_entry(path, nested_mapping, node_line(nested.fetch(:key)))
          else
            warnings << missing_adapter_warning(path)
          end
        rescue DatabaseParseError => e
          mapping_child = true
          warnings << entry_alias_warning(path, e)
        end
      end
      warnings << missing_adapter_warning("production") unless mapping_child

      [entries, warnings]
    end
    private_class_method :production_entries

    def database_entry(path, mapping, line)
      { path: path, mapping: mapping, line: line }
    end
    private_class_method :database_entry

    def analyze_database_entry(entry, anchors)
      adapter_entry = entry.fetch(:mapping).fetch("adapter")
      adapter = scalar_value(adapter_entry.fetch(:value), anchors).to_s
      return [[], []] if adapter == SQLITE_ADAPTER

      unless POSTGRES_ADAPTERS.include?(adapter) || MYSQL_ADAPTERS.include?(adapter)
        warning = "#{DATABASE_FILE} #{entry.fetch(:path)} uses unsupported adapter #{adapter.inspect} — " \
                  "database timeout checks were inactive for this entry."
        return [[], [warning]]
      end

      findings = statement_timeout_findings(entry, adapter, anchors)
      findings.concat(connect_timeout_findings(entry, anchors))
      [findings, []]
    end
    private_class_method :analyze_database_entry

    def statement_timeout_findings(entry, adapter, anchors)
      variables = entry.fetch(:mapping)["variables"]
      return [missing_statement_timeout(entry, adapter)] unless variables

      variables_node = dereference(variables.fetch(:value), anchors)
      unless mapping?(variables_node)
        return [unresolvable_timeout(entry, "variables", variables.fetch(:value), anchors)]
      end

      variable_entries = mapping_entries(variables_node, anchors)
      keys = POSTGRES_ADAPTERS.include?(adapter) ? ["statement_timeout"] :
        %w[max_execution_time max_statement_time]
      present = keys.filter_map do |key|
        timeout_entry = variable_entries[key]
        [key, timeout_entry] if timeout_entry
      end
      return [missing_statement_timeout(entry, adapter)] if present.empty?

      present.filter_map do |key, timeout_entry|
        statement_timeout_finding(entry, key, timeout_entry, anchors)
      end
    end
    private_class_method :statement_timeout_findings

    def statement_timeout_finding(entry, key, timeout_entry, anchors)
      raw_value = scalar_value(timeout_entry.fetch(:value), anchors)
      seconds = timeout_seconds(key, raw_value)
      if raw_value&.include?("<%") || seconds.nil?
        return unresolvable_timeout(entry, key, timeout_entry.fetch(:value), anchors)
      end
      return disabled_statement_timeout(entry, key, raw_value, timeout_entry) if seconds.zero?
      return negative_statement_timeout(entry, key, raw_value, timeout_entry) if seconds.negative?

      threshold = statement_timeout_threshold
      return unless seconds > threshold

      message = "#{entry.fetch(:path)} sets #{key} to #{raw_value.inspect} " \
                "(#{formatted_seconds(seconds)}s), above the suggested ≤ #{threshold}s ceiling; " \
                "a slow query can hold its connection too long. Suggested: ≤ #{threshold}s " \
                "(guide example: 5s)."
      message = mysql_limitation(message) if key == "max_execution_time"
      finding(
        rule: "Resilience/StatementTimeoutTooHigh",
        message: message,
        file: DATABASE_FILE,
        line: node_line(timeout_entry.fetch(:value)),
        discriminator: entry.fetch(:path),
        confidence: "high"
      )
    end
    private_class_method :statement_timeout_finding

    def missing_statement_timeout(entry, adapter)
      keys = if POSTGRES_ADAPTERS.include?(adapter)
               "statement_timeout"
             else
               "max_execution_time or max_statement_time"
             end
      threshold = statement_timeout_threshold
      message = "#{entry.fetch(:path)} sets no #{keys}; a hung query holds its connection " \
                "indefinitely. Suggested: ≤ #{threshold}s (guide example: 5s)."
      message = mysql_limitation(message) if MYSQL_ADAPTERS.include?(adapter)
      finding(
        rule: "Resilience/MissingStatementTimeout",
        message: message,
        file: DATABASE_FILE,
        line: entry.fetch(:line),
        discriminator: entry.fetch(:path),
        confidence: "high"
      )
    end
    private_class_method :missing_statement_timeout

    def disabled_statement_timeout(entry, key, raw_value, timeout_entry)
      threshold = statement_timeout_threshold
      message = "#{entry.fetch(:path)} sets #{key} to #{raw_value.inspect}, explicitly disabled; " \
                "a hung query holds its connection indefinitely. Suggested: ≤ #{threshold}s " \
                "(guide example: 5s)."
      message = mysql_limitation(message) if key == "max_execution_time"
      finding(
        rule: "Resilience/MissingStatementTimeout",
        message: message,
        file: DATABASE_FILE,
        line: node_line(timeout_entry.fetch(:value)),
        discriminator: entry.fetch(:path),
        confidence: "high"
      )
    end
    private_class_method :disabled_statement_timeout

    def negative_statement_timeout(entry, key, raw_value, timeout_entry)
      threshold = statement_timeout_threshold
      message = "#{entry.fetch(:path)} sets #{key} to #{raw_value.inspect}, which is not a valid " \
                "finite timeout; a hung query remains unbounded. Suggested: a positive value " \
                "≤ #{threshold}s (guide example: 5s)."
      if key == "statement_timeout"
        message = "#{message} PostgreSQL rejects negative statement_timeout values."
      elsif key == "max_execution_time"
        message = mysql_limitation(message)
      end
      finding(
        rule: "Resilience/MissingStatementTimeout",
        message: message,
        file: DATABASE_FILE,
        line: node_line(timeout_entry.fetch(:value)),
        discriminator: entry.fetch(:path),
        confidence: "high"
      )
    end
    private_class_method :negative_statement_timeout

    def connect_timeout_findings(entry, anchors)
      connect_timeout = entry.fetch(:mapping)["connect_timeout"]
      unless connect_timeout
        return [finding(
          rule: "Resilience/MissingConnectTimeout",
          message: "#{entry.fetch(:path)} sets no connect_timeout; establishing a database " \
                   "connection can wait indefinitely. Suggested: set a finite connect_timeout.",
          file: DATABASE_FILE,
          line: entry.fetch(:line),
          discriminator: entry.fetch(:path),
          confidence: "high"
        )]
      end

      raw_value = scalar_value(connect_timeout.fetch(:value), anchors)
      seconds = timeout_seconds("connect_timeout", raw_value)
      if raw_value&.include?("<%") || seconds.nil?
        return [unresolvable_timeout(entry, "connect_timeout", connect_timeout.fetch(:value), anchors)]
      end
      return [] if seconds.positive?

      [finding(
        rule: "Resilience/MissingConnectTimeout",
        message: "#{entry.fetch(:path)} sets connect_timeout to #{raw_value.inspect}; Zero, " \
                 "negative, or not specified means wait indefinitely. Suggested: set a positive " \
                 "finite connect_timeout.",
        file: DATABASE_FILE,
        line: node_line(connect_timeout.fetch(:value)),
        discriminator: entry.fetch(:path),
        confidence: "high"
      )]
    end
    private_class_method :connect_timeout_findings

    def unresolvable_timeout(entry, key, value_node, anchors)
      raw_value = scalar_value(value_node, anchors)
      finding(
        rule: "Resilience/UnresolvableTimeoutValue",
        message: "#{entry.fetch(:path)} sets #{key} to #{raw_value.inspect}; static analysis " \
                 "cannot resolve it to a number or known duration unit without evaluating target " \
                 "code. Suggested: use a statically visible finite timeout.",
        file: DATABASE_FILE,
        line: node_line(value_node),
        discriminator: entry.fetch(:path),
        confidence: "low"
      )
    end
    private_class_method :unresolvable_timeout

    def mysql_limitation(message)
      "#{message} MySQL max_execution_time is SELECT-only; writes stay unbounded even when it is set."
    end
    private_class_method :mysql_limitation

    def timeout_seconds(key, raw_value)
      return unless raw_value

      case key
      when "statement_timeout"
        integer?(raw_value) ? raw_value.to_i / 1000.0 : duration_seconds(raw_value)
      when "max_execution_time"
        raw_value.to_i / 1000.0 if integer?(raw_value)
      when "max_statement_time"
        raw_value.to_f if number?(raw_value)
      when "connect_timeout"
        number?(raw_value) ? raw_value.to_f : duration_seconds(raw_value)
      end
    end
    private_class_method :timeout_seconds

    def duration_seconds(value)
      match = value.match(/\A([+-]?\d+(?:\.\d+)?)(ms|s|min)\z/i)
      return unless match

      amount = match[1].to_f
      { "ms" => amount / 1000.0, "s" => amount, "min" => amount * 60 }.fetch(match[2].downcase)
    end
    private_class_method :duration_seconds

    def integer?(value)
      value.match?(/\A[+-]?\d+\z/)
    end
    private_class_method :integer?

    def number?(value)
      value.match?(/\A[+-]?\d+(?:\.\d+)?\z/)
    end
    private_class_method :number?

    def formatted_seconds(value)
      value.to_i == value ? value.to_i : value
    end
    private_class_method :formatted_seconds

    def statement_timeout_threshold
      Mappings::RESILIENCE_THRESHOLDS.fetch(:statement_timeout_max_seconds)
    end
    private_class_method :statement_timeout_threshold

    def mapping_entries(node, anchors, stack = [])
      node = dereference(node, anchors)
      return {} unless mapping?(node)
      return {} if stack.include?(node.object_id)

      next_stack = stack + [node.object_id]
      merged = {}
      explicit = {}
      node.children.each_slice(2) do |key_node, value_node|
        key = scalar_value(key_node, anchors)
        if key == "<<"
          merge_nodes(value_node, anchors).reverse_each do |merge_node|
            merged.merge!(mapping_entries(merge_node, anchors, next_stack))
          end
        else
          explicit[key] = { key: key_node, value: value_node }
        end
      end
      merged.merge(explicit)
    end
    private_class_method :mapping_entries

    def merge_nodes(node, anchors)
      resolved = dereference(node, anchors)
      return resolved.children if resolved.is_a?(Psych::Nodes::Sequence)

      [node]
    end
    private_class_method :merge_nodes

    def collect_anchors(root)
      anchors = {}
      visit = lambda do |node|
        if !node.is_a?(Psych::Nodes::Alias) && node.respond_to?(:anchor) && node.anchor
          anchors[node.anchor] = node
        end
        Array(node.children).each { |child| visit.call(child) } if node.respond_to?(:children)
      end
      visit.call(root)
      anchors
    end
    private_class_method :collect_anchors

    def dereference(node, anchors)
      return node unless node.is_a?(Psych::Nodes::Alias)

      anchors.fetch(node.anchor) do
        raise DatabaseParseError, "invalid YAML: unresolved alias #{node.anchor.inspect}"
      end
    end
    private_class_method :dereference

    def scalar_value(node, anchors)
      resolved = dereference(node, anchors)
      resolved.value if resolved.is_a?(Psych::Nodes::Scalar)
    end
    private_class_method :scalar_value

    def mapping?(node)
      node.is_a?(Psych::Nodes::Mapping)
    end
    private_class_method :mapping?

    def null_scalar?(node)
      return false unless node.is_a?(Psych::Nodes::Scalar)

      node.tag == "tag:yaml.org,2002:null" ||
        (node.plain && node.value.match?(/\A(?:|~|null)\z/i))
    end
    private_class_method :null_scalar?

    def node_line(node)
      node.start_line + 1
    end
    private_class_method :node_line

    def missing_database_warning
      "#{DATABASE_FILE} not found — database timeout checks were inactive; the config may live " \
        "elsewhere, so this does not mean timeouts are set."
    end
    private_class_method :missing_database_warning

    def unparseable_database_warning(reason)
      "#{DATABASE_FILE} could not be statically parsed (#{reason}) — database timeout checks " \
        "were inactive."
    end
    private_class_method :unparseable_database_warning

    def missing_adapter_warning(path)
      "#{DATABASE_FILE} #{path} has no statically visible adapter — database timeout checks were " \
        "inactive for this entry."
    end
    private_class_method :missing_adapter_warning

    def production_not_defined_warning
      "The production environment is not defined in #{DATABASE_FILE} — database timeout checks " \
        "were inactive; this is common in DATABASE_URL-only apps."
    end
    private_class_method :production_not_defined_warning

    def entry_alias_warning(path, error)
      "#{DATABASE_FILE} #{path} has #{error.message} — database timeout checks were inactive for " \
        "this entry."
    end
    private_class_method :entry_alias_warning

    def missing_lockfile_warning
      "#{LOCKFILE} not found — request-timeout middleware detection was inactive."
    end
    private_class_method :missing_lockfile_warning

    def finding(rule:, message:, file:, line:, discriminator:, confidence:)
      {
        "rule" => rule,
        "message" => message,
        "file" => file,
        "line" => line,
        "discriminator" => discriminator,
        "confidence" => confidence
      }
    end
    private_class_method :finding

    def result(payload:, output_path:, warnings:)
      {
        name: "resilience",
        version: RailsAudit::VERSION,
        raw_count: payload.size,
        exit_code: 0,
        payload: payload,
        output_path: output_path,
        warnings: warnings
      }
    end
    private_class_method :result
  end
end
