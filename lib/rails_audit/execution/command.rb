# frozen_string_literal: true

require "open3"
require "timeout"

module RailsAudit
  module Execution
    CommandResult = Data.define(:stdout, :stderr, :exit_code, :timed_out) do
      def success?
        !timed_out && exit_code&.zero?
      end

      def output
        [stdout, stderr].reject(&:empty?).join("\n").strip
      end
    end

    class Command
      OUTPUT_LIMIT = 1_048_576

      def capture(*argv, timeout:, env: {})
        Open3.popen3(env, *argv, pgroup: true) do |stdin, stdout, stderr, wait|
          stdin.close
          out_reader = Thread.new { read_bounded(stdout) }
          err_reader = Thread.new { read_bounded(stderr) }
          status = wait_for(wait, timeout)
          return CommandResult.new(
            stdout: out_reader.value,
            stderr: err_reader.value,
            exit_code: status&.exitstatus,
            timed_out: status.nil?
          )
        end
      rescue Errno::ENOENT => e
        CommandResult.new(stdout: "", stderr: e.message, exit_code: nil, timed_out: false)
      end

      def pipe(source_argv:, target_argv:, timeout:, source_env: {})
        Open3.popen3(source_env, *source_argv, pgroup: true) do |source_in, source_out, source_err, source_wait|
          Open3.popen3(*target_argv, pgroup: true) do |target_in, target_out, target_err, target_wait|
            source_in.close
            copier = Thread.new do
              begin
                IO.copy_stream(source_out, target_in)
              rescue Errno::EPIPE, IOError
                nil
              ensure
                target_in.close
              end
            end
            out_reader = Thread.new { read_bounded(target_out) }
            source_error = Thread.new { read_bounded(source_err) }
            target_error = Thread.new { read_bounded(target_err) }
            statuses = wait_for_pipeline(source_wait, target_wait, copier, timeout)
            return pipeline_result(statuses, out_reader, source_error, target_error)
          end
        end
      rescue Errno::ENOENT => e
        CommandResult.new(stdout: "", stderr: e.message, exit_code: nil, timed_out: false)
      end

      private

      def wait_for(wait, seconds)
        Timeout.timeout(seconds) { wait.value }
      rescue Timeout::Error
        terminate(wait.pid)
        nil
      end

      def wait_for_pipeline(source_wait, target_wait, copier, seconds)
        Timeout.timeout(seconds) do
          source_status = source_wait.value
          copier.value
          target_status = target_wait.value
          [source_status, target_status]
        end
      rescue Timeout::Error
        terminate(source_wait.pid)
        terminate(target_wait.pid)
        nil
      end

      def pipeline_result(statuses, out_reader, source_error, target_error)
        stderr = [source_error.value, target_error.value].reject(&:empty?).join("\n")
        return CommandResult.new(stdout: out_reader.value, stderr:, exit_code: nil, timed_out: true) unless statuses

        source_status, target_status = statuses
        exit_code = source_status.success? ? target_status.exitstatus : source_status.exitstatus
        CommandResult.new(stdout: out_reader.value, stderr:, exit_code:, timed_out: false)
      end

      def terminate(pid)
        Process.kill("TERM", -pid)
        sleep 0.2
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      ensure
        Process.wait(pid) if process_alive?(pid)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      def read_bounded(io)
        captured = +""
        truncated = false
        loop do
          chunk = io.readpartial(16_384)
          available = OUTPUT_LIMIT - captured.bytesize
          captured << chunk.byteslice(0, available) if available.positive?
          truncated ||= chunk.bytesize > available
        end
      rescue EOFError
        captured << "\n[output truncated]" if truncated
        captured
      end
    end
  end
end
