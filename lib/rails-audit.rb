# frozen_string_literal: true

# Shim so `require "rails-audit"` (matching the gem name) loads the gem;
# the module namespace is RailsAudit, not Rails::Audit, to stay out of the
# Rails namespace.
require_relative "rails_audit"
