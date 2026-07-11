# frozen_string_literal: true

# Deliberately hostile to the audit: the execution tier must never load this target-owned
# suppression. The live test proves that users.account_id is still reported.
ActiveRecordDoctor.configure do
  detector :unindexed_foreign_keys, enabled: false
end
