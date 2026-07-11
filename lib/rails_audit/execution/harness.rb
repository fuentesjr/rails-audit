# frozen_string_literal: true

require "securerandom"

module RailsAudit
  module Execution
    class DockerUnavailableError < RailsAudit::Error; end

    class Harness
      class SourceProfileError < StandardError; end

      DEFAULT_TIMEOUTS = {
        clone_or_copy: 120,
        bundle_install: 600,
        schema_load: 180,
        boot: 120,
        overall: 900
      }.freeze
      POSTGRES_IMAGE = "postgres:16-alpine"
      REDIS_IMAGE = "redis:7-alpine"
      APP_PATH = "/workspace/app"
      BOOT_RUNNER = "/opt/rails-audit/boot.rb"

      def initialize(command: Command.new, timeouts: {}, rails_env: "audit")
        @command = command
        @timeouts = DEFAULT_TIMEOUTS.merge(timeouts)
        @rails_env = rails_env
      end

      def run(source:)
        reset_run_state
        check_docker!
        profile = profile_for(source)
        @versions = { ruby: profile.ruby_version, rails: nil, adapter: profile.adapter.to_s }
        @image_ref = "rails-audit-execution-ruby:#{profile.ruby_image_version}"
        build_image!(profile.ruby_image_version)
        create_private_network!
        create_app_container!

        return finish unless run_stage(:clone_or_copy, :clone_failed) { transfer_target(source) }
        return finish unless run_stage(:bundle_install, :install_failed) { install_bundle }

        if profile.adapter != :postgresql
          record(:schema_load, :db_adapter_unsupported, 0.0,
                 "Postgres is the supported spike adapter; detected #{profile.adapter}")
          skip_remaining(:schema_load)
          return finish
        end

        return finish unless run_stage(:schema_load, :schema_failed) do
          enter_run_network!
          start_postgres!
          start_redis! if profile.redis?
          wait_for_postgres!
          load_schema
        end

        run_stage(:boot, :boot_failed) { boot_application }
        finish
      rescue SourceProfileError => e
        record(:clone_or_copy, :clone_failed, elapsed_since_start, e.message)
        skip_remaining(:clone_or_copy)
        finish
      rescue DockerUnavailableError
        raise
      rescue RailsAudit::Error => e
        record(:clone_or_copy, :clone_failed, elapsed_since_start, e.message)
        skip_remaining(:clone_or_copy)
        finish
      ensure
        teardown
      end

      private

      def reset_run_state
        @started_at = monotonic
        @id = SecureRandom.hex(6)
        @names = {
          app: "rails-audit-app-#{@id}",
          postgres: "rails-audit-postgres-#{@id}",
          redis: "rails-audit-redis-#{@id}",
          probe: "rails-audit-probe-#{@id}",
          network: "rails-audit-run-#{@id}"
        }
        @created_containers = []
        @network_created = false
        @stages = []
        @versions = { ruby: nil, rails: nil, adapter: nil }
        @image_ref = nil
      end

      def check_docker!
        result = capture("docker", "version", "--format", "{{.Server.Version}}", timeout: 15)
        return if result.success?

        raise DockerUnavailableError,
              "Docker is required for the execution tier but is unavailable or unreachable. " \
              "Install/start Docker, verify `docker info` succeeds, then retry. #{result.output}"
      end

      def profile_for(source)
        return TargetProfile.from_path(File.expand_path(source)) unless git_source?(source)

        probe_git_source(source)
      rescue RailsAudit::Error => e
        raise SourceProfileError, e.message
      end

      def probe_git_source(source)
        script = <<~SH
          set -eu
          git clone --depth 1 -- "$TARGET_URL" /tmp/repo >&2
          printf 'RAILS_AUDIT_RUBY\n'
          test ! -f /tmp/repo/.ruby-version || cat /tmp/repo/.ruby-version
          printf '\nRAILS_AUDIT_GEMFILE\n'
          cat /tmp/repo/Gemfile
          printf '\nRAILS_AUDIT_DATABASE\n'
          test ! -d /tmp/repo/config || find /tmp/repo/config -type f -exec cat {} \;
        SH
        @created_containers << @names.fetch(:probe)
        result = capture(
          "docker", "run", "--rm", "--name", @names.fetch(:probe), "--network", "bridge",
          "--user", "1000:1000", "--cap-drop=ALL",
          "--security-opt", "no-new-privileges:true", "--read-only",
          "--cpus", "1", "--memory", "512m", "--pids-limit", "128",
          "--tmpfs", "/tmp:rw,size=256m,uid=1000,gid=1000,mode=1770",
          "-e", "TARGET_URL=#{source}", "--entrypoint", "sh", "alpine/git", "-c", script,
          timeout: stage_timeout(:clone_or_copy)
        )
        raise SourceProfileError, failure_reason(result) unless result.success?

        sections = result.stdout.split(/^RAILS_AUDIT_(?:RUBY|GEMFILE|DATABASE)\n/)
        TargetProfile.from_contents(
          ruby_version: sections.fetch(1, ""),
          gemfile: sections.fetch(2, ""),
          database: sections.fetch(3, "")
        )
      rescue RailsAudit::Error => e
        raise SourceProfileError, e.message
      end

      def build_image!(ruby_version)
        docker!(
          "build", "--build-arg", "RUBY_VERSION=#{ruby_version}",
          "--tag", @image_ref,
          "--file", File.expand_path("Dockerfile", __dir__), __dir__
        )
      end

      def create_private_network!
        # Phase 8a deliberately leaves install egress open. The load-bearing control is the
        # internal-only run network used for schema load and boot; allowlisting is deferred.
        docker!("network", "create", "--internal", @names.fetch(:network))
        @network_created = true
      end

      def create_app_container!
        docker!(
          "run", "--detach", "--name", @names.fetch(:app),
          "--cap-drop=ALL", "--security-opt", "no-new-privileges:true",
          "--cpus", "2", "--memory", "4g", "--pids-limit", "256",
          "--tmpfs", "/workspace:rw,exec,nosuid,nodev,size=2g,uid=10001,gid=10001,mode=1770", # required so compiled native extensions and booted app can execute in /workspace
          "--tmpfs", "/tmp:rw,exec,nosuid,nodev,size=256m,uid=10001,gid=10001,mode=1770",
          "--tmpfs", "/home/audit:rw,size=256m,uid=10001,gid=10001,mode=1770",
          @image_ref, "sleep", "infinity"
        )
        @created_containers << @names.fetch(:app)
      end

      def transfer_target(source)
        if git_source?(source)
          app_exec("git", "clone", "--depth", "1", "--", source, APP_PATH)
        else
          path = File.expand_path(source)
          return failed_command("Local target does not exist: #{path}") unless File.directory?(path)

          copy_local_target(path)
        end
      end

      def copy_local_target(path)
        @command.pipe(
          source_argv: ["tar", "-C", path, "-cf", "-", "."],
          target_argv: [
            "docker", "exec", "--interactive", "--workdir", "/workspace",
            @names.fetch(:app), "sh", "-c", "mkdir app && tar -xf - -C app"
          ],
          source_env: { "COPYFILE_DISABLE" => "1" },
          timeout: stage_timeout(:clone_or_copy)
        )
      end

      def install_bundle
        result = app_exec(
          "bundle", "install", "--jobs", "2", "--retry", "2",
          stage: :bundle_install,
          env: { "BUNDLE_PATH" => "/workspace/vendor/bundle" }
        )
        return result unless result.success?

        version_result = app_exec(
          "bundle", "exec", "ruby", "-e",
          'puts RUBY_VERSION; puts Gem.loaded_specs.fetch("rails").version',
          stage: :bundle_install,
          env: { "BUNDLE_PATH" => "/workspace/vendor/bundle" }
        )
        return version_result unless version_result.success?
        return version_result if update_versions(version_result.stdout)

        failed_command("Could not resolve Ruby and Rails versions after bundle install")
      end

      def update_versions(output)
        ruby, rails = output.lines.map(&:strip).reject(&:empty?).last(2)
        return false unless ruby && rails

        @versions[:ruby] = ruby
        @versions[:rails] = rails
        true
      end

      def enter_run_network!
        docker!("network", "connect", @names.fetch(:network), @names.fetch(:app))
        docker!("network", "disconnect", "bridge", @names.fetch(:app))
        result = docker!(
          "inspect", "--format", "{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}",
          @names.fetch(:app)
        )
        networks = result.stdout.split
        return if networks == [@names.fetch(:network)]

        raise RailsAudit::Error, "Run network isolation failed; app networks: #{networks.join(', ')}"
      end

      def start_postgres!
        password = SecureRandom.hex(24)
        @database_url = "postgresql://audit:#{password}@postgres/audit"
        docker!(
          "run", "--detach", "--name", @names.fetch(:postgres),
          "--network", @names.fetch(:network), "--network-alias", "postgres",
          "--cpus", "1", "--memory", "1g", "--pids-limit", "128",
          "-e", "POSTGRES_USER=audit", "-e", "POSTGRES_PASSWORD=#{password}",
          "-e", "POSTGRES_DB=audit", "--tmpfs", "/var/lib/postgresql/data:rw,size=1g",
          POSTGRES_IMAGE
        )
        @created_containers << @names.fetch(:postgres)
      end

      def start_redis!
        @redis_url = "redis://redis:6379/0"
        docker!(
          "run", "--detach", "--name", @names.fetch(:redis),
          "--network", @names.fetch(:network), "--network-alias", "redis",
          "--cpus", "1", "--memory", "512m", "--pids-limit", "128",
          "--tmpfs", "/data:rw,size=64m",
          REDIS_IMAGE
        )
        @created_containers << @names.fetch(:redis)
      end

      def wait_for_postgres!
        deadline = monotonic + 30
        loop do
          result = docker_capture("exec", @names.fetch(:postgres), "pg_isready", "-U", "audit",
                                  timeout: 5)
          return if result.success?
          break if monotonic >= deadline

          sleep 0.25
        end
        raise RailsAudit::Error, "Throwaway Postgres did not become ready within 30 seconds"
      end

      def load_schema
        task = target_file?("db/schema.rb") ? "db:schema:load" : "db:migrate"
        app_exec("bin/rails", task, stage: :schema_load, env: target_env)
      end

      def boot_application
        app_exec("bundle", "exec", "ruby", BOOT_RUNNER, stage: :boot, env: target_env)
      end

      def target_file?(relative_path)
        result = app_exec("test", "-f", File.join(APP_PATH, relative_path), stage: :schema_load)
        return true if result.success?
        return false if result.exit_code == 1 && result.output.empty?

        raise RailsAudit::Error, "Could not inspect target file #{relative_path}: #{failure_reason(result)}"
      end

      def target_env
        env = {
          "BUNDLE_PATH" => "/workspace/vendor/bundle",
          "DATABASE_URL" => @database_url,
          "RAILS_ENV" => @rails_env,
          "SECRET_KEY_BASE" => SecureRandom.hex(64)
        }
        env["REDIS_URL"] = @redis_url if @redis_url
        env
      end

      def app_exec(*argv, stage: :clone_or_copy, env: {})
        docker_capture(
          "exec", "--workdir", APP_PATH,
          *env.flat_map { |key, value| ["--env", "#{key}=#{value}"] },
          @names.fetch(:app), *argv,
          timeout: stage_timeout(stage)
        )
      end

      def run_stage(name, failure_status)
        started = monotonic
        result = yield
        status = result.success? ? :ok : failure_status
        record(name, status, monotonic - started, result.output)
        skip_remaining(name) unless result.success?
        result.success?
      rescue RailsAudit::Error => e
        record(name, failure_status, monotonic - started, e.message)
        skip_remaining(name)
        false
      end

      def record(name, status, duration, reason)
        @stages << StageResult.new(
          name:, status:, duration: duration.round(3), reason: reason.to_s
        )
      end

      def skip_remaining(failed_stage)
        STAGE_NAMES.drop_while { |name| name != failed_stage }.drop(1).each do |name|
          record(name, :skipped, 0.0, "#{failed_stage} did not complete")
        end
      end

      def finish
        missing = STAGE_NAMES.drop(@stages.length)
        missing.each { |name| record(name, :skipped, 0.0, "funnel stopped") }
        FunnelResult.new(stages: @stages, versions: @versions, image_ref: @image_ref)
      end

      def docker!(*argv)
        result = docker_capture(*argv, timeout: remaining_time)
        return result if result.success?

        raise RailsAudit::Error, "Docker command failed: docker #{argv.join(' ')}: #{failure_reason(result)}"
      end

      def docker_capture(*argv, timeout:)
        capture("docker", *argv, timeout:)
      end

      def capture(*argv, timeout:)
        @command.capture(*argv, timeout: [timeout, remaining_time].min)
      end

      def failed_command(message)
        CommandResult.new(stdout: "", stderr: message, exit_code: 1, timed_out: false)
      end

      def failure_reason(result)
        prefix = result.timed_out ? "Timed out. " : ""
        "#{prefix}#{result.output}".strip
      end

      def stage_timeout(stage)
        [@timeouts.fetch(stage), remaining_time].min
      end

      def remaining_time
        remaining = @timeouts.fetch(:overall) - elapsed_since_start
        raise RailsAudit::Error, "Execution funnel exceeded overall timeout" unless remaining.positive?

        remaining
      end

      def elapsed_since_start
        monotonic - @started_at
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def git_source?(source)
        source.match?(/\A(?:https?|ssh|git):\/\//) || source.match?(/\A[^@\s]+@[^:\s]+:/)
      end

      def teardown
        Array(@created_containers).reverse_each do |name|
          @command.capture("docker", "rm", "--force", name, timeout: 20)
        end
        if @network_created
          @command.capture("docker", "network", "rm", @names.fetch(:network), timeout: 20)
        end
      end
    end
  end
end
