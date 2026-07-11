# frozen_string_literal: true

require "json"
require "fileutils"
require "tempfile"

module RailsAudit
  module ExecutionAudit
    STATIC_FILENAMES = %w[findings.json RAILS_AUDIT_REPORT.md].freeze

    module_function

    def run(target:, output_path: "execution-findings.json",
            report_path: "EXECUTION_AUDIT_REPORT.md", harness: Execution::Harness.new,
            stdout: $stdout)
      validate_paths!(output_path, report_path)
      result = harness.run(source: target)
      document = document(target, result)
      atomic_write(output_path, JSON.pretty_generate(document))
      atomic_write(report_path, Report.render_execution(document))
      stdout.puts "#{document.fetch(:findings).size} execution findings — " \
                  "outcome #{document.fetch(:outcome)}; " \
                  "artifact written to #{output_path}; report written to #{report_path}"
      result.outcome == :ok ? 0 : 1
    end

    def document(target, result)
      serialized = result.to_h
      {
        target: target,
        tier: "execution",
        pinned_by_us: false,
        warranted_reproducible: false,
        outcome: serialized.fetch(:outcome),
        resolved_versions: serialized.fetch(:resolved_versions).reject { |key, _value| key == :adapter },
        container_image_ref: serialized.fetch(:container_image_ref),
        container_image_digest: serialized.fetch(:container_image_digest),
        db_adapter: result.versions.fetch(:adapter, nil),
        funnel_stages: funnel_stages(serialized.fetch(:stages)),
        tool_runs: serialized.fetch(:tool_runs),
        findings: serialized.fetch(:findings)
      }
    end
    private_class_method :document

    def funnel_stages(stages)
      stages.transform_values do |stage|
        stage.fetch(:status) == "ok" ? stage.merge(reason: "") : stage
      end
    end
    private_class_method :funnel_stages

    def validate_paths!(output_path, report_path)
      paths = [output_path, report_path].map { |path| File.expand_path(path) }
      if paths.uniq.length == 1
        raise RailsAudit::Error, "Execution artifact and report paths must be different"
      end

      reserved = paths.map { |path| File.basename(path) } & STATIC_FILENAMES
      return if reserved.empty?

      raise RailsAudit::Error,
            "Execution audit cannot write reserved static output #{reserved.join(', ')}"
    end
    private_class_method :validate_paths!

    def atomic_write(path, content)
      expanded = File.expand_path(path)
      directory = File.dirname(expanded)
      FileUtils.mkdir_p(directory)
      Tempfile.create(["rails-audit-execution", File.extname(expanded)], directory) do |file|
        file.write(content)
        file.flush
        file.fsync
        File.rename(file.path, expanded)
      end
    end
    private_class_method :atomic_write
  end
end
