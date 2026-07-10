# frozen_string_literal: true

require "tmpdir"
require "test_helper"

# Guards against a silent false negative: if config/rails_audit/rubocop.yml
# ever stops loading the rubocop-rails / rubocop-performance plugins, entire
# finding categories would disappear while the report still looks clean.
class RubocopPluginCopsTest < Minitest::Test
  TARGET = File.expand_path("../fixtures/plugin_cop_app", __dir__)

  def test_cli_owned_config_loads_rails_and_performance_cops
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "rubocop.json")

      result = RailsAudit::Runners.rubocop(target: TARGET, output_path: output_path)

      cop_names = result.fetch(:payload).fetch("files")
        .flat_map { |file| file.fetch("offenses") }
        .map { |offense| offense.fetch("cop_name") }

      assert(cop_names.any? { |name| name.start_with?("Rails/") },
             "expected at least one Rails/* offense, got: #{cop_names}")
      assert(cop_names.any? { |name| name.start_with?("Performance/") },
             "expected at least one Performance/* offense, got: #{cop_names}")
    end
  end
end
