# frozen_string_literal: true

require "tmpdir"
require "test_helper"

# Guards against a silent false negative in the other direction from
# RubocopPluginCopsTest: config ownership (--config) bypasses the target's
# own AllCops: Exclude, so the CLI must ship its own minimal Exclude list
# (DESIGN.md §9) or it lints generated files the target never hand-edits.
# The list must stay narrow — db/migrate/** and other real app code are
# deliberately NOT excluded.
class RubocopExcludeTest < Minitest::Test
  TARGET = File.expand_path("../fixtures/exclude_app", __dir__)

  def test_excludes_generated_schema_but_still_surfaces_app_offenses
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "rubocop.json")

      with_environment("XDG_CACHE_HOME" => File.join(dir, "cache")) do
        result = RailsAudit::Runners.rubocop(target: TARGET, output_path: output_path)

        offense_files = result.fetch(:payload).fetch("files")
          .select { |file| file.fetch("offenses").any? }
          .map { |file| file.fetch("path") }

        refute(offense_files.any? { |path| path.end_with?("db/schema.rb") },
               "expected db/schema.rb to be excluded, got offenses in: #{offense_files}")
        assert(offense_files.any? { |path| path.end_with?("app/models/thing.rb") },
               "expected app/models/thing.rb offenses to still surface, got: #{offense_files}")
      end
    end
  end

  private

  def with_environment(values)
    original = values.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
