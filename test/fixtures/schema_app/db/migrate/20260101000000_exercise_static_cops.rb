# frozen_string_literal: true

class WrongMigrationName < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :admin, :boolean
    add_column :users, :save, :string
    add_column :users, :account_id, :integer, index: true
    add_column :users, :name, :string, null: false
    remove_column :users, :legacy
  end
end
