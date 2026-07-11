# frozen_string_literal: true

class User < ApplicationRecord
  # Seeded issue (intentional): the account_id foreign-key column has no
  # covering index (see db/schema.rb). Targets active_record_doctor's
  # `unindexed_foreign_keys` check.
  belongs_to :account
  has_many :posts, dependent: :destroy

  # Seeded issue (intentional): validates uniqueness with no matching unique
  # DB index on users.email (see db/schema.rb). Targets active_record_doctor's
  # `missing_unique_indexes` check.
  validates :email, presence: true, uniqueness: true
end
