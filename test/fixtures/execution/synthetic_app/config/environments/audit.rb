# frozen_string_literal: true

# Dedicated boot environment for the execution-tier harness. Deliberately not
# named "development" or "test": Rails only falls back to
# ENV["SECRET_KEY_BASE"] (skipping credentials/master.key) for environments
# other than development/test, which is exactly the env-var-only boot this
# fixture requires (see docs/execution-tier-proposal.md §3.3).
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_level = :info

  config.active_support.report_deprecations = false

  # No credentials.yml.enc / master.key in this fixture. Fail loudly instead
  # of falling back to Rails' auto-generated dev secret if this file is ever
  # loaded without SECRET_KEY_BASE set.
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE")
end
