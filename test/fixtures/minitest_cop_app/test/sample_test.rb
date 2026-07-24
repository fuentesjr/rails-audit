# frozen_string_literal: true

class SampleTest < Minitest::Test
  # Minitest/AssertNil (Enabled: true upstream — proves the plugin loads at all).
  def test_value_is_absent
    assert_equal(nil, compute)
  end

  # Minitest/SkipEnsure (ensure still runs when the test is skipped; the cop needs a
  # statement between skip and ensure to fire) — `pending` upstream, enabled by the
  # CLI-owned config.
  def test_skip_with_ensure
    skip "not ready"

    compute
  ensure
    cleanup
  end

  # Minitest/UnreachableAssertion (assertion at the bottom of an assert_raises block,
  # never reached once the raise happens) — `pending` upstream, enabled by the
  # CLI-owned config.
  def test_error_is_raised
    assert_raises(RuntimeError) do
      boom
      assert_equal(1, compute)
    end
  end

  # Minitest/UselessAssertion — `pending` upstream, enabled by the CLI-owned config.
  def test_always_passes
    assert true
  end

  def compute
    nil
  end

  def boom
    raise "boom"
  end

  def cleanup; end
end
