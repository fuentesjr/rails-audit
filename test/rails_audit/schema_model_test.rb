# frozen_string_literal: true

require "tempfile"
require "test_helper"

class SchemaModelTest < Minitest::Test
  SCHEMA_PATH = File.expand_path("../fixtures/schema_app/db/schema.rb", __dir__)

  def test_loads_tables_columns_indices_options_and_foreign_keys_with_lines
    model = RailsAudit::SchemaModel.load(SCHEMA_PATH)
    legacy_events = model.table("legacy_events")
    orders = model.table("orders")
    posts = model.table("posts")
    manual_keys = model.table("manual_keys")
    foreign_key = model.foreign_keys.fetch(0)

    assert_equal false, legacy_events.options.fetch(:id)
    assert_equal 8, legacy_events.line
    assert_equal({ name: "account_id", type: :integer, null: false, line: 21,
                   primary_key: false },
                 orders.columns.fetch(0).to_h)
    assert_equal ["category"], posts.indices.fetch(0).columns
    assert_equal 28, posts.indices.fetch(0).line
    assert_equal ["category", "published_at"], posts.indices.fetch(1).columns
    assert_equal 46, posts.indices.fetch(1).line
    assert_equal "index_posts_on_category_and_published_at", posts.indices.fetch(1).name
    assert_equal({ from: "orders", to: "accounts", column: "account_id", primary_key: "id",
                  line: 48 }, foreign_key.to_h)
    assert manual_keys.primary_key?
    assert_equal "code", manual_keys.primary_key_name
    assert_equal :string, manual_keys.primary_key_type
  end

  def test_raises_when_an_existing_schema_cannot_be_parsed
    Tempfile.create(["schema", ".rb"]) do |file|
      file.write("ActiveRecord::Schema.define do\n  create_table(\nend\n")
      file.flush

      error = assert_raises(RailsAudit::Error) { RailsAudit::SchemaModel.load(file.path) }

      assert_includes error.message, "could not parse"
      assert_includes error.message, file.path
    end
  end
end
