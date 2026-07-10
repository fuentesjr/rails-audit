# frozen_string_literal: true

require_relative "rails_audit/version"
require_relative "rails_audit/finding"
require_relative "rails_audit/mappings"
require_relative "rails_audit/normalizer"
require_relative "rails_audit/report"

module RailsAudit
  class Error < StandardError; end
end

require_relative "rails_audit/runners"
require_relative "rails_audit/cli"
