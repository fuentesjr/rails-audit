# frozen_string_literal: true

require "json"
require "test_helper"

class CollisionMeasurementTest < Minitest::Test
  TARGET_ROOT = "target/lobsters"

  def test_real_reek_fixture_has_no_id_collisions_after_normalization
    findings = RailsAudit::Normalizer.normalize(
      brakeman: { "warnings" => [] },
      rubocop: { "files" => [] },
      reek: raw_fixture("reek.json"),
      target_root: TARGET_ROOT
    )

    assert_equal 1_700, findings.size
    assert_equal 0, collision_group_count(findings)
    assert_equal findings.size, findings.map(&:id).uniq.size
  end

  def test_combined_real_tool_fixtures_have_unique_ids
    findings = RailsAudit::Normalizer.normalize(
      brakeman: raw_fixture("brakeman.json"),
      rubocop: raw_fixture("rubocop.json"),
      reek: raw_fixture("reek.json"),
      target_root: TARGET_ROOT
    )

    assert_equal findings.size, findings.map(&:id).uniq.size
  end

  private

  def collision_group_count(findings)
    findings.group_by(&:id).count { |_id, group| group.size > 1 }
  end

  def raw_fixture(name)
    path = File.expand_path("../fixtures/raw/#{name}", __dir__)
    JSON.parse(File.read(path))
  end
end
