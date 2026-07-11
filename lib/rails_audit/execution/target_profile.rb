# frozen_string_literal: true

module RailsAudit
  module Execution
    class TargetProfile
      attr_reader :ruby_version, :adapter

      def self.from_path(path)
        ruby_version = read(File.join(path, ".ruby-version"))
        gemfile = read(File.join(path, "Gemfile"))
        configuration = Dir.glob(File.join(path, "config", "**", "*"))
                           .select { |entry| File.file?(entry) }
                           .map { |entry| read(entry) }
                           .join("\n")
        from_contents(ruby_version:, gemfile:, database: configuration)
      end

      def self.from_contents(ruby_version:, gemfile:, database:)
        declared_ruby = parse_ruby_version(ruby_version, gemfile)
        new(
          ruby_version: declared_ruby,
          adapter: parse_adapter(database, gemfile),
          redis: redis_required?(gemfile, database)
        )
      end

      def self.parse_ruby_version(version_file, gemfile)
        version = version_file.to_s.strip.sub(/\Aruby-/, "")
        version = gemfile.to_s[/^\s*ruby\s+["']([^"']+)["']/, 1] if version.empty?
        unless version&.match?(/\A\d+\.\d+(?:\.\d+)?\z/)
          raise RailsAudit::Error,
                "Cannot resolve target Ruby version from .ruby-version or Gemfile"
        end

        version
      end
      private_class_method :parse_ruby_version

      def self.parse_adapter(database, gemfile)
        contents = "#{database}\n#{gemfile}"
        return :mysql if contents.match?(/(?:adapter:\s*(?:mysql|trilogy)|gem\s+["']mysql2["'])/i)
        return :postgresql if contents.match?(/(?:adapter:\s*(?:postgres|postgresql)|gem\s+["']pg["'])/i)
        return :sqlite if contents.match?(/(?:adapter:\s*sqlite|gem\s+["']sqlite3["'])/i)

        :unknown
      end
      private_class_method :parse_adapter

      def self.redis_required?(gemfile, database)
        "#{gemfile}\n#{database}".match?(/REDIS_URL|gem\s+["']redis(?:-rails)?["']/i)
      end
      private_class_method :redis_required?

      def self.read(path)
        File.file?(path) ? File.read(path) : ""
      end
      private_class_method :read

      def initialize(ruby_version:, adapter:, redis:)
        @ruby_version = ruby_version
        @adapter = adapter
        @redis = redis
        freeze
      end

      def ruby_image_version
        ruby_version
      end

      def redis?
        @redis
      end
    end
  end
end
