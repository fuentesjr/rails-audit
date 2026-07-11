# frozen_string_literal: true

# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations to incrementally modify
# your database, and then regenerate this schema definition.
#
# This fixture has no db/migrate/ directory — the schema below is
# hand-authored to be internally consistent with app/models/*, since the
# harness only ever runs `db:schema:load`, never migrations (see
# docs/execution-tier-proposal.md §3.2).

ActiveRecord::Schema[7.2].define(version: 2026_07_10_000000) do
  create_table "accounts", force: :cascade do |t|
    t.string "name", null: false
  end

  create_table "users", force: :cascade do |t|
    # Seeded issue: no index on account_id. See app/models/user.rb
    # (active_record_doctor `unindexed_foreign_keys`).
    t.bigint "account_id", null: false
    # Seeded issue: User validates uniqueness of email, but there is no
    # matching unique index here. See app/models/user.rb
    # (active_record_doctor `missing_unique_indexes`).
    t.string "email", null: false
  end

  create_table "posts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "title", null: false
    t.index ["user_id"], name: "index_posts_on_user_id"
  end
end
