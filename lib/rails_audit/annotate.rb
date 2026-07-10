# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

module RailsAudit
  module Annotate
    DEFAULT_TIMEOUT = 180
    DEFAULT_RETRIES = 1
    InvocationResult = Struct.new(:stdout, :stderr, :exit_status, :timed_out, keyword_init: true)

    class SubprocessRunner
      def call(argv, timeout:)
        stdout_text = stderr_text = nil
        exit_status = nil
        timed_out = false

        Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stdout_reader = Thread.new { stdout.read }
          stderr_reader = Thread.new { stderr.read }

          unless wait_thread.join(timeout)
            timed_out = true
            terminate_group(wait_thread.pid, wait_thread)
          end

          exit_status = wait_thread.value.exitstatus unless timed_out
          stdout_text = stdout_reader.value
          stderr_text = stderr_reader.value
        end

        InvocationResult.new(
          stdout: stdout_text, stderr: stderr_text, exit_status: exit_status, timed_out: timed_out
        )
      end

      private

      def terminate_group(pid, wait_thread)
        signal_group("TERM", pid)
        return if wait_thread.join(1)

        signal_group("KILL", pid)
        wait_thread.join
      end

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end
    end

    module_function

    def run(findings_path:, output_path: "ANNOTATIONS.md", runner: SubprocessRunner.new,
            timeout: DEFAULT_TIMEOUT, retries: DEFAULT_RETRIES, stdout: $stdout, stderr: $stderr)
      document = JSON.parse(File.read(findings_path))
      prompt = prompt_for(DigestBuilder.build(document))
      argv = ["claude", "-p", "--output-format", "json", prompt]
      last_result = nil

      (retries + 1).times do
        last_result = runner.call(argv, timeout: timeout)
        annotation, metadata = parse_success(last_result)
        next unless annotation

        write_annotations(output_path, annotation)
        stdout.puts "Annotations written to #{output_path}"
        stdout.puts metadata_line(metadata) unless metadata.empty?
        return 0
      end

      diagnostic = last_result&.stderr.to_s.strip
      stderr.puts "Annotation failed after #{retries + 1} attempts: #{diagnostic.empty? ? 'no stderr' : diagnostic}"
      1
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError, KeyError => e
      stderr.puts "Annotation failed: #{e.message}"
      1
    end

    def prompt_for(digest)
      # "Impact" follows the v2 vocabulary; the spike's older prompt called this "Severity".
      headers = [
        "Top 5 issues to fix first",
        "Systemic patterns",
        "Refactoring suggestions (thoughtbot style)",
        "Impact ranking critique"
      ]
      <<~PROMPT
        You are reviewing a deterministic Rails static-analysis digest. Provide judgment and
        prioritization only; do not invent new findings. Return Markdown with exactly these four
        headers and no others:

        #{headers.map { |header| "## #{header}" }.join("\n")}

        Digest:
        #{digest}
      PROMPT
    end
    private_class_method :prompt_for

    def parse_success(result)
      return [nil, {}] if result.nil? || result.timed_out || result.exit_status != 0 || result.stdout.to_s.strip.empty?

      envelope = JSON.parse(result.stdout)
      annotation = envelope["result"]
      return [nil, {}] unless annotation.is_a?(String) && !annotation.strip.empty?

      metadata = envelope.slice("total_cost_usd", "cost_usd", "usage")
      [annotation, metadata]
    rescue JSON::ParserError
      [nil, {}]
    end
    private_class_method :parse_success

    def metadata_line(metadata)
      parts = []
      parts << "total_cost_usd=#{metadata['total_cost_usd']}" if metadata.key?("total_cost_usd")
      parts << "cost_usd=#{metadata['cost_usd']}" if metadata.key?("cost_usd")
      parts << "usage=#{JSON.generate(metadata['usage'])}" if metadata.key?("usage")
      "Claude cost/usage: #{parts.join(' ')}"
    end
    private_class_method :metadata_line

    def write_annotations(path, annotation)
      content = <<~MARKDOWN
        # rails-audit annotations

        > **UNVERIFIED second opinion:** This content has not been independently verified and is
        > not ground truth. Treat it as a second opinion.

        #{annotation.rstrip}
      MARKDOWN

      directory = File.dirname(File.expand_path(path))
      Tempfile.create(["rails-audit-annotations", ".md"], directory) do |file|
        file.write(content)
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
    end
    private_class_method :write_annotations
  end
end
