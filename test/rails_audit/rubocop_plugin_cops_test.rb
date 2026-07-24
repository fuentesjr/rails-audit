# frozen_string_literal: true

require "tmpdir"
require "test_helper"

# Guards against a silent false negative: if config/rails_audit/rubocop.yml
# ever stops loading the rubocop-rails / rubocop-performance plugins, entire
# finding categories would disappear while the report still looks clean.
class RubocopPluginCopsTest < Minitest::Test
  TARGET = File.expand_path("../fixtures/plugin_cop_app", __dir__)
  MINITEST_TARGET = File.expand_path("../fixtures/minitest_cop_app", __dir__)

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

  def test_cli_owned_config_loads_minitest_cops
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "rubocop.json")

      result = RailsAudit::Runners.rubocop(target: MINITEST_TARGET, output_path: output_path)

      cop_names = result.fetch(:payload).fetch("files")
        .flat_map { |file| file.fetch("offenses") }
        .map { |offense| offense.fetch("cop_name") }

      assert_includes cop_names, "Minitest/AssertNil",
                       "expected a Minitest/AssertNil offense, got: #{cop_names}"

      # The three correctness cops are `pending` upstream and only fire because
      # config/rails_audit/rubocop.yml enables them explicitly — assert each one
      # so a future rubocop-minitest bump that renames or drops any of them (or a
      # config regression that loses the overrides) fails loudly instead of going
      # silently dark.
      %w[Minitest/UnreachableAssertion Minitest/SkipEnsure Minitest/UselessAssertion].each do |cop|
        assert_includes cop_names, cop,
                        "expected a #{cop} offense (pending upstream, enabled by our config), got: #{cop_names}"
      end
    end
  end
end
