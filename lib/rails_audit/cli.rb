# frozen_string_literal: true

require "bundler"
require "fileutils"
require "json"
require "optparse"

module RailsAudit
  class CLI
    USAGE = <<~USAGE
      Usage: rails-audit audit TARGET [options]
             rails-audit annotate FINDINGS_JSON [--output PATH]

      Options:
              --output-dir DIR          Directory to write outputs (default: .)
              --respect-target-config   Respect the target app's own brakeman ignore file
    USAGE

    def initialize(stdout: $stdout, stderr: $stderr, claude_runner: nil)
      @stdout = stdout
      @stderr = stderr
      @claude_runner = claude_runner
    end

    def run(argv)
      command, *rest = argv

      case command
      when "audit"
        audit(rest)
      when "annotate"
        annotate(rest)
      else
        usage_error
      end
    rescue RailsAudit::Error => e
      @stderr.puts e.message
      1
    end

    private

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
      options = { output_dir: "." }
      parser = OptionParser.new do |opts|
        opts.on("--output-dir DIR") { |dir| options[:output_dir] = dir }
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
                   respect_target_config: options[:respect_target_config] || false)
    end

    def run_pipeline(target:, output_dir:, respect_target_config:)
      raw_dir = File.join(output_dir, "raw")

      brakeman = Runners.brakeman(
        target: target,
        output_path: File.join(raw_dir, "brakeman.json"),
        respect_target_config: respect_target_config
      )
      rubocop = Runners.rubocop(target: target, output_path: File.join(raw_dir, "rubocop.json"))
      reek = Runners.reek(target: target, output_path: File.join(raw_dir, "reek.json"))

      findings = Normalizer.normalize(
        brakeman: brakeman.fetch(:payload),
        rubocop: rubocop.fetch(:payload),
        reek: reek.fetch(:payload),
        target_root: target
      )

      document = Normalizer.document(
        target: target,
        toolchain: { ruby: RUBY_VERSION, bundler: Bundler::VERSION },
        tools: [brakeman, rubocop, reek].map { |tool| tool.slice(:name, :version, :raw_count, :exit_code) },
        findings: findings
      )

      write_outputs(output_dir, document)
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
