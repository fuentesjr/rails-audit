# frozen_string_literal: true

require "bundler"
require "fileutils"
require "json"
require "optparse"

module RailsAudit
  class CLI
    DEFAULT_MAX_FINDINGS = 500_000

    # rubocop-rails schema cops (Rails/UniqueValidationWithoutIndex, Rails/ThreeStateBooleanColumn, ...)
    # read db/schema.rb directly and silently no-op when it's absent (structure.sql targets, or repos
    # that don't commit schema.rb). Silent skips are the exact false-negative class this tool exists to
    # surface, so we call it out explicitly instead of letting "no findings" read as "schema is fine".
    SCHEMA_MISSING_WARNING =
      "db/schema.rb not found — schema-dependent cops (e.g. Rails/UniqueValidationWithoutIndex, " \
      "Rails/ThreeStateBooleanColumn) and Schema/* checks were inactive; migration cops on " \
      "db/migrate are unaffected."

    USAGE = <<~USAGE
      Usage: rails-audit audit TARGET [options]
             rails-audit annotate FINDINGS_JSON [--output PATH]
             rails-audit execution-audit TARGET --i-understand-untrusted-code-runs [options]

      Options:
              --output-dir DIR          Directory to write outputs (default: .)
              --max-findings N          Maximum findings before failure (default: 500000)
              --respect-target-config   Respect the target app's own brakeman ignore file
              --output PATH             Execution findings path (default: execution-findings.json)
              --report PATH             Execution report path (default: EXECUTION_AUDIT_REPORT.md)
    USAGE

    def initialize(stdout: $stdout, stderr: $stderr, claude_runner: nil, execution_harness: nil)
      @stdout = stdout
      @stderr = stderr
      @claude_runner = claude_runner
      @execution_harness = execution_harness
    end

    def run(argv)
      command, *rest = argv

      case command
      when "audit"
        audit(rest)
      when "annotate"
        annotate(rest)
      when "execution-audit"
        execution_audit(rest)
      else
        usage_error
      end
    rescue RailsAudit::Error => e
      @stderr.puts e.message
      1
    end

    private

    def execution_audit(argv)
      options = {
        output: "execution-findings.json", report: "EXECUTION_AUDIT_REPORT.md",
        acknowledged: false
      }
      parser = OptionParser.new do |opts|
        opts.on("--output PATH") { |path| options[:output] = path }
        opts.on("--report PATH") { |path| options[:report] = path }
        opts.on("--i-understand-untrusted-code-runs") { options[:acknowledged] = true }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        @stderr.puts e.message
        return usage_error
      end

      target = argv.shift
      return usage_error unless target && argv.empty?
      unless options[:acknowledged]
        @stderr.puts "Refusing to run untrusted target code. Re-run with " \
                     "--i-understand-untrusted-code-runs to acknowledge arbitrary code execution."
        return 1
      end

      arguments = {
        target: File.expand_path(target), output_path: File.expand_path(options[:output]),
        report_path: File.expand_path(options[:report]), stdout: @stdout
      }
      arguments[:harness] = @execution_harness if @execution_harness
      ExecutionAudit.run(**arguments)
    end

    def annotate(argv)
      options = { output: "ANNOTATIONS.md" }
      parser = OptionParser.new do |opts|
        opts.on("--output PATH") { |path| options[:output] = path }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        @stderr.puts e.message
        return usage_error
      end

      findings_path = argv.shift
      return usage_error unless findings_path && argv.empty?

      arguments = {
        findings_path: File.expand_path(findings_path), output_path: File.expand_path(options[:output]),
        stdout: @stdout, stderr: @stderr
      }
      arguments[:runner] = @claude_runner if @claude_runner
      Annotate.run(**arguments)
    end

    def audit(argv)
      options = { output_dir: ".", max_findings: DEFAULT_MAX_FINDINGS }
      parser = OptionParser.new do |opts|
        opts.on("--output-dir DIR") { |dir| options[:output_dir] = dir }
        opts.on("--max-findings N", Integer) do |max_findings|
          raise OptionParser::InvalidArgument, "must be greater than 0" unless max_findings.positive?

          options[:max_findings] = max_findings
        end
        opts.on("--respect-target-config") { options[:respect_target_config] = true }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        @stderr.puts e.message
        return usage_error
      end

      target = argv.shift
      return usage_error unless target

      run_pipeline(target: File.expand_path(target), output_dir: File.expand_path(options[:output_dir]),
                   respect_target_config: options[:respect_target_config] || false,
                   max_findings: options[:max_findings])
    end

    def run_pipeline(target:, output_dir:, respect_target_config:, max_findings:)
      raw_dir = File.join(output_dir, "raw")
      FileUtils.mkdir_p(raw_dir)

      brakeman_thread = Thread.new do
        Thread.current.report_on_exception = false
        Runners.brakeman(
          target: target,
          output_path: File.join(raw_dir, "brakeman.json"),
          respect_target_config: respect_target_config
        )
      end
      rubocop_thread = Thread.new do
        Thread.current.report_on_exception = false
        Runners.rubocop(target: target, output_path: File.join(raw_dir, "rubocop.json"))
      end
      reek_thread = Thread.new do
        Thread.current.report_on_exception = false
        Runners.reek(target: target, output_path: File.join(raw_dir, "reek.json"))
      end
      schema_thread = Thread.new do
        Thread.current.report_on_exception = false
        SchemaAnalyzer.analyze(target: target, output_path: File.join(raw_dir, "schema.json"))
      end

      threads = {
        brakeman: brakeman_thread, rubocop: rubocop_thread, reek: reek_thread,
        schema: schema_thread
      }
      results = {}
      error = nil
      # Join every thread (any error type) before re-raising so a failing runner never orphans
      # the others; the first error still propagates.
      threads.each do |name, thread|
        results[name] = thread.value
      rescue StandardError => e
        error ||= e
      end
      raise error if error

      brakeman = results.fetch(:brakeman)
      rubocop = results.fetch(:rubocop)
      reek = results.fetch(:reek)
      schema = results.fetch(:schema)

      findings = Normalizer.normalize(
        brakeman: brakeman.fetch(:payload),
        rubocop: rubocop.fetch(:payload),
        reek: reek.fetch(:payload),
        schema: schema.fetch(:payload),
        target_root: target
      )
      if findings.size > max_findings
        raise RailsAudit::Error,
              "Audit produced #{findings.size} findings, exceeding the --max-findings cap of " \
              "#{max_findings}. Re-run with a higher --max-findings value or narrow the target."
      end

      document = Normalizer.document(
        target: target,
        toolchain: { ruby: RUBY_VERSION, bundler: Bundler::VERSION },
        tools: [brakeman, rubocop, reek, schema].map do |tool|
          tool.slice(:name, :version, :raw_count, :exit_code)
        end,
        findings: findings,
        warnings: warnings_for(target)
      )

      write_outputs(output_dir, document)
    end

    def warnings_for(target)
      return [] if File.exist?(File.join(target, "db", "schema.rb"))

      [SCHEMA_MISSING_WARNING]
    end

    def write_outputs(output_dir, document)
      FileUtils.mkdir_p(output_dir)
      findings_path = File.join(output_dir, "findings.json")
      report_path = File.join(output_dir, "RAILS_AUDIT_REPORT.md")

      File.write(findings_path, JSON.pretty_generate(document))
      File.write(report_path, Report.render(document))

      @stdout.puts "#{document.fetch(:findings).size} findings — report written to #{report_path}"
      0
    end

    def usage_error
      @stderr.puts USAGE
      1
    end
  end
end
