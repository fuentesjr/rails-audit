# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create do |t|
  # Default globs (test/**/*_test.rb, test/**/test_*.rb) would also pick up and
  # actually *execute* fixture files under test/fixtures/**/*_test.rb (e.g. the
  # rubocop-minitest fixtures, which are static source for the real rubocop runner
  # to lint, not tests this suite should run itself). Scope to the real test tree.
  # Both default naming forms (*_test.rb and test_*.rb) are kept for the real test
  # tree so a future prefix-named file doesn't silently never run.
  t.test_globs = ["test/test_*.rb", "test/rails_audit/**/*_test.rb", "test/rails_audit/**/test_*.rb"]
end

task default: :test
