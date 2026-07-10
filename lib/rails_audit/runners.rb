# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tempfile"

module RailsAudit
  module Runners
    ROOT = File.expand_path("../..", __dir__)
    GEMFILE_LOCK = File.join(ROOT, "Gemfile.lock")
    RUBOCOP_CONFIG = File.join(ROOT, "config", "rails_audit", "rubocop.yml")
    EMPTY_BRAKEMAN_IGNORE = '{"ignored_warnings":[],"updated":null}'
    EXIT_CODES = {
      "brakeman" => { 0 => "no warnings", 3 => "warnings found" },
      "rubocop" => { 0 => "no offenses", 1 => "offenses found" },
      "reek" => { 0 => "no smells", 2 => "smells found" }
    }.freeze

    class MissingOutputError < RailsAudit::Error; end

    module_function

    def brakeman(target:, output_path:, respect_target_config: false,
                 capture: Open3.method(:capture3))
      FileUtils.mkdir_p(File.dirname(output_path))

      if respect_target_config
        run_brakeman(target:, output_path:, capture:)
      else
        Tempfile.create(["rails-audit-brakeman-ignore", ".json"]) do |ignore|
          ignore.write(EMPTY_BRAKEMAN_IGNORE)
          ignore.flush
          run_brakeman(target:, output_path:, capture:, ignore_path: ignore.path)
        end
      end
    end

    def rubocop(target:, output_path:, capture: Open3.method(:capture3))
      FileUtils.mkdir_p(File.dirname(output_path))
      FileUtils.rm_f(output_path)
      env = { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") }
      argv = [
        "bundle", "exec", "rubocop", ".",
        "--config", RUBOCOP_CONFIG,
        "--format", "json", "--out", output_path
      ]
      _stdout, stderr, status = capture.call(env, *argv, chdir: target)
      if !EXIT_CODES.fetch("rubocop").key?(status.exitstatus) &&
         (!File.exist?(output_path) || File.empty?(output_path))
        raise MissingOutputError,
              "rubocop exited with unexpected code #{status.exitstatus} and produced " \
              "missing or empty output at #{output_path}: #{stderr}"
      end

      check_exit_code!("rubocop", status.exitstatus, stderr)
      payload = JSON.parse(File.read(output_path))
      result(
        name: "rubocop",
        output_path: output_path,
        payload: payload,
        exit_code: status.exitstatus,
        raw_count: payload.fetch("summary").fetch("offense_count")
      )
    end

    def reek(target:, output_path:, capture: Open3.method(:capture3))
      FileUtils.mkdir_p(File.dirname(output_path))
      argv = ["bundle", "exec", "reek", target, "--format", "json"]
      stdout, stderr, status = capture.call(*argv, chdir: ROOT)
      File.write(output_path, stdout)
      check_exit_code!("reek", status.exitstatus, stderr)
      payload = JSON.parse(File.read(output_path))

      result(
        name: "reek",
        output_path: output_path,
        payload: payload,
        exit_code: status.exitstatus,
        raw_count: payload.size
      )
    end

    def run_brakeman(target:, output_path:, capture:, ignore_path: nil)
      argv = [
        "bundle", "exec", "brakeman", "-p", target, "-f", "json", "-o", output_path
      ]
      argv.concat(["-i", ignore_path]) if ignore_path
      _stdout, stderr, status = capture.call(*argv, chdir: ROOT)
      check_exit_code!("brakeman", status.exitstatus, stderr)
      payload = JSON.parse(File.read(output_path))

      result(
        name: "brakeman",
        output_path: output_path,
        payload: payload,
        exit_code: status.exitstatus,
        raw_count: payload.fetch("warnings").size
      )
    end
    private_class_method :run_brakeman

    def check_exit_code!(tool, exit_code, stderr)
      known = EXIT_CODES.fetch(tool)
      return if known.key?(exit_code)

      raise RailsAudit::Error,
            "#{tool} exited with unexpected code #{exit_code} " \
            "(known: #{known.keys.sort}): #{stderr}"
    end
    private_class_method :check_exit_code!

    def result(name:, output_path:, payload:, exit_code:, raw_count:)
      {
        name: name,
        version: gem_version(name),
        output_path: output_path,
        payload: payload,
        exit_code: exit_code,
        raw_count: raw_count
      }
    end
    private_class_method :result

    def gem_version(name)
      match = File.read(GEMFILE_LOCK).match(/^    #{Regexp.escape(name)} \(([^)]+)\)$/)
      raise RailsAudit::Error, "#{name} is missing from Gemfile.lock" unless match

      match[1]
    end
    private_class_method :gem_version
  end
end
