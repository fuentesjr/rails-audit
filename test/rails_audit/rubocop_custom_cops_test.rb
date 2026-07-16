# frozen_string_literal: true

require "tmpdir"
require "test_helper"

class RubocopCustomCopsTest < Minitest::Test
  TARGET = File.expand_path("../fixtures/cops_app", __dir__)

  def test_real_runner_loads_custom_cops_and_limits_them_to_intended_files
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "rubocop.json")

      result = with_environment("XDG_CACHE_HOME" => File.join(dir, "cache")) do
        RailsAudit::Runners.rubocop(target: TARGET, output_path: output_path)
      end
      offenses_by_file = result.fetch(:payload).fetch("files").to_h do |file|
        [File.basename(file.fetch("path")), file.fetch("offenses").map { |offense| offense.fetch("cop_name") }]
      end

      assert_includes offenses_by_file.fetch("fat_record.rb"), "RailsAudit/FatModel"
      assert_includes offenses_by_file.fetch("reports_controller.rb"),
                      "RailsAudit/FatControllerAction"

      refute_includes offenses_by_file.fetch("slim_record.rb"), "RailsAudit/FatModel"
      refute_includes offenses_by_file.fetch("health_controller.rb"),
                      "RailsAudit/FatControllerAction"
      # Presence of app/services/** is not an audit finding (application-operations R7 removed).
      service_offenses = offenses_by_file.fetch("report_generator.rb", [])
      refute_includes service_offenses, "RailsAudit/ServiceObject"

      findings = RailsAudit::Normalizer.rubocop(result.fetch(:payload), target_root: TARGET)
      fat_model = findings.find { |finding| finding.rule == "RailsAudit/FatModel" }
      fat_action = findings.find { |finding| finding.rule == "RailsAudit/FatControllerAction" }

      assert_equal ["medium", "complexity"], [fat_model.impact, fat_model.category]
      assert_equal ["medium", "complexity"], [fat_action.impact, fat_action.category]
      assert_equal "app/models/fat_record.rb", fat_model.location.fetch(:file)
      assert_nil findings.find { |finding| finding.rule == "RailsAudit/ServiceObject" }
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
