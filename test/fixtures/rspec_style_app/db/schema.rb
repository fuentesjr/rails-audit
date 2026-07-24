# frozen_string_literal: true

ActiveRecord::Schema[7.0].define(version: 20_260_101_000_000) do
  create_table "widgets", force: :cascade do |t|
    t.string "name"
  end
end
