# frozen_string_literal: true

require_relative "boot"

require "rails"
# Only the frameworks this fixture actually needs: ActiveRecord (for the
# models/schema under audit) and ActiveModel (its dependency). No
# ActionController/View/Mailer/Cable/Storage/Text/Mailbox — there is no web
# layer, no assets, no JS runtime, and nothing that needs Redis to boot.
require "active_model/railtie"
require "active_record/railtie"

Bundler.require(*Rails.groups)

module SyntheticApp
  class Application < Rails::Application
    config.load_defaults 7.2

    # No credentials.yml.enc/master.key anywhere in this fixture — see
    # config/environments/audit.rb for how secret_key_base and the database
    # connection are provisioned from ENV only.
    config.require_master_key = false
  end
end
