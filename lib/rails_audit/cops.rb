# frozen_string_literal: true

require "rubocop"
require_relative "cops/direct_methods"
require_relative "cops/fat_model"
require_relative "cops/fat_controller_action"
require_relative "cops/timeout_module_use"
require_relative "cops/net_http_default_timeouts"
require_relative "cops/net_http_missing_timeout"
require_relative "cops/faraday_missing_timeout"
require_relative "cops/httparty_missing_timeout"
require_relative "cops/rack_timeout_disabled"
