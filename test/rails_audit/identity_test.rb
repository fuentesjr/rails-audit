# frozen_string_literal: true

require "json"
require "test_helper"

class IdentityTest < Minitest::Test
  TARGET_ROOT = "target/lobsters"

  def test_brakeman_native_fingerprint_collision_gets_distinct_compound_ids
    findings = RailsAudit::Normalizer.brakeman(
      fixture("brakeman_native_fingerprint.json"),
      target_root: TARGET_ROOT
    )

    assert_equal 1, findings.map(&:native_fingerprint).uniq.size
    assert_equal 2, findings.map(&:id).uniq.size
  end

  def test_rubocop_same_line_offenses_get_distinct_ids_from_column
    findings = RailsAudit::Normalizer.rubocop(
      fixture("rubocop_columns.json"),
      target_root: TARGET_ROOT
    )

    assert_equal [5, 24], (findings.map { |finding| finding.location[:column] })
    assert_equal 2, findings.map(&:id).uniq.size
  end

  def test_reek_duplicate_method_call_pair_still_collides_in_phase_one
    findings = RailsAudit::Normalizer.reek(
      fixture("reek_duplicate_method_call.json"),
      target_root: TARGET_ROOT
    )

    # DESIGN sections 5 and 9 defer Reek's name-based discriminator to Phase 2.
    assert_equal 1, findings.map(&:id).uniq.size
    assert_equal "34443701043ed54d", findings.first.id
  end

  private

  def fixture(name)
    path = File.expand_path("../fixtures/collisions/#{name}", __dir__)
    JSON.parse(File.read(path))
  end
end
