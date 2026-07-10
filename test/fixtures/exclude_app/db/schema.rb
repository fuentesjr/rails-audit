# frozen_string_literal: true

# This file should be excluded from linting by the CLI-owned rubocop config
# (config/rails_audit/rubocop.yml). The Style/NilComparison offense below
# exists only so the test can confirm the exclude actually suppresses it.
ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do
  create_table "things", force: :cascade do |t|
    t.string "name"
  end
end

FIXTURE_OFFENSE = 1 if 1 == nil
