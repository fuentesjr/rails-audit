# frozen_string_literal: true

require_relative "rails_audit/version"
require_relative "rails_audit/finding"
require_relative "rails_audit/mappings"
require_relative "rails_audit/normalizer"
require_relative "rails_audit/report"
require_relative "rails_audit/digest_builder"
require_relative "rails_audit/annotate"
require_relative "rails_audit/execution_audit"

module RailsAudit
  class Error < StandardError; end
end

require_relative "rails_audit/runners"
require_relative "rails_audit/execution"
require_relative "rails_audit/schema_model"
require_relative "rails_audit/schema_analyzer"
require_relative "rails_audit/cli"
