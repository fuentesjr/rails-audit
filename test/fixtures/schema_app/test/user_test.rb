# frozen_string_literal: true

# Exists so this fixture counts as a Minitest-using target (no MINITEST_MISSING_WARNING).
# The assertion is deliberately non-literal: `assert true` would itself be a
# Minitest/UselessAssertion offense and pollute tests that audit this fixture.
class UserTest < Minitest::Test
  def test_name_length
    assert_equal 4, "user".length
  end
end
