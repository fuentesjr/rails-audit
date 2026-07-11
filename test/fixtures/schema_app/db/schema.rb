# frozen_string_literal: true

ActiveRecord::Schema[7.0].define(version: 20_260_101_000_000) do
  create_table "users", force: :cascade do |t|
    t.string "email"
  end

  create_table "legacy_events", id: false, force: :cascade do |t|
    t.string "payload"
  end

  create_table "short_records", id: :integer, force: :cascade do |t|
    t.string "name"
  end

  create_table "accounts", force: :cascade do |t|
    t.string "name"
  end

  create_table "orders", force: :cascade do |t|
    t.integer "account_id", null: false
    t.bigint "owner_id"
  end

  create_table "posts", force: :cascade do |t|
    t.string "category"
    t.datetime "published_at"
    t.index ["category"], name: "index_posts_on_category"
  end

  create_table "attachments", force: :cascade do |t|
    t.string "attachable_type", null: false
    t.bigint "attachable_id", null: false
    t.index ["attachable_type", "attachable_id"], name: "index_attachments_on_attachable"
  end

  create_table "inferred_comments", force: :cascade do |t|
    t.integer "user_id"
    t.index ["user_id"], name: "index_inferred_comments_on_user_id"
  end

  create_table "manual_keys", id: false, force: :cascade do |t|
    t.primary_key "code", type: :string
  end

  add_index "posts", ["category", "published_at"], name: "index_posts_on_category_and_published_at"
  add_index "accounts", ["id"], name: "index_accounts_on_id"
  add_foreign_key "orders", "accounts", column: "account_id"
end
