# frozen_string_literal: true

require "test_helper"
require "rails_audit/cops"

class RubocopResilienceCopsTest < Minitest::Test
  def test_timeout_module_use_flags_only_explicit_timeout_constant_calls
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::TimeoutModuleUse,
      <<~RUBY
        Timeout.timeout(1) { work }
        ::Timeout.timeout(2) { work }
      RUBY
    )

    assert_equal 2, offenses.size
    assert_includes offenses.first.message, "arbitrary points"
    assert_includes offenses.first.message, "corrupt state"

    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::TimeoutModuleUse,
      <<~RUBY
        timeout(1) { work }
        Other::Timeout.timeout(1) { work }
        timeout_client.timeout(1) { work }
      RUBY
    )
  end

  def test_net_http_default_timeouts_flags_only_module_level_shortcuts
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpDefaultTimeouts,
      <<~RUBY
        Net::HTTP.get(uri)
        Net::HTTP.get_response(uri)
        Net::HTTP.post_form(uri, payload)
      RUBY
    )

    assert_equal 3, offenses.size
    assert(offenses.all? { |offense| offense.message.include?("60s defaults") })

    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpDefaultTimeouts,
      <<~RUBY
        client.get(uri)
        Net::HTTP.request(uri)
        MyHTTP.get(uri)
      RUBY
    )
  end

  def test_net_http_missing_timeout_flags_construction_without_local_timeout_evidence
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def build_client
          Net::HTTP.new(host, port)
        end

        def start_client
          Net::HTTP.start(host)
        end
      RUBY
    )

    assert_equal 2, offenses.size
    assert(offenses.all? { |offense| offense.message.include?("enclosing method") })
  end

  def test_net_http_missing_timeout_accepts_keywords_or_setters_in_the_enclosing_method
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def configured_with_keyword
          Net::HTTP.start(host, open_timeout: 2)
        end

        def configured_with_setter
          http = Net::HTTP.new(host)
          http.read_timeout = 5
        end

        def configured_after_construction
          http = Net::HTTP.new(host)
          http.write_timeout = 5
        end

        def configured_in_start_block
          Net::HTTP.start(host) { |http| http.read_timeout = 5 }
        end
      RUBY
    )
  end

  def test_net_http_missing_timeout_accepts_timeout_keywords_on_start_only
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          Net::HTTP.new("example.com", open_timeout: 2, read_timeout: 3)
          Net::HTTP.start("example.com", open_timeout: 2, read_timeout: 3)
        end
      RUBY
    )

    assert_equal [2], offense_lines(offenses)
  end

  def test_net_http_missing_timeout_correlates_assignment_through_tap_only
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          http = Net::HTTP.new("example.com").tap { |connection| connection.use_ssl = true }
          http.read_timeout = 2
        end
      RUBY
    )

    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          http = Net::HTTP.new("example.com").then { |connection| connection }
          http.read_timeout = 2
        end
      RUBY
    )

    assert_equal [2], offense_lines(offenses)
  end

  def test_net_http_missing_timeout_accepts_assigned_tap_with_in_block_timeout
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def client
          http = Net::HTTP.new("example.com").tap { |connection| connection.read_timeout = 2 }
          use(http)
        end
      RUBY
    )
  end

  def test_net_http_missing_timeout_correlates_memoizing_or_assignment
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def client
          @http ||= Net::HTTP.new("example.com")
          @http.read_timeout = 2
        end
      RUBY
    )
  end

  def test_net_http_missing_timeout_treats_memoizing_or_assignment_as_reassignment_boundary
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def client
          @http = Net::HTTP.new("one.example")
          @http ||= Net::HTTP.new("two.example")
          @http.read_timeout = 2
        end
      RUBY
    )

    assert_equal [2], offense_lines(offenses)
  end

  def test_net_http_missing_timeout_accepts_numbered_and_it_configuration_blocks
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          Net::HTTP.start("one.example") { _1.read_timeout = 2 }
          Net::HTTP.new("two.example").tap { it.open_timeout = 1 }
          Net::HTTP.new("three.example").then { _1.write_timeout = 3 }
          Net::HTTP.new("four.example").yield_self { it.read_timeout = 4 }

          first = Net::HTTP.new("five.example").tap { _1.use_ssl = true }
          first.read_timeout = 5
          second = Net::HTTP.new("six.example").tap { it.use_ssl = true }
          second.open_timeout = 6
        end
      RUBY
    )
  end

  def test_net_http_missing_timeout_correlates_top_level_setters
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        http = Net::HTTP.new("example.com")
        http.read_timeout = 5
      RUBY
    )
  end

  def test_net_http_missing_timeout_accepts_attribute_or_assignment_setters
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def client
          http = Net::HTTP.new("example.com")
          http.read_timeout ||= 2
        end
      RUBY
    )
  end

  def test_net_http_missing_timeout_preserves_documented_v1_non_goals
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          http, port = Net::HTTP.new("one.example"), 80
          http.read_timeout = 2
          Net::HTTP.start("two.example", "open_timeout" => 2)
          Net::HTTP&.start("three.example")

          bounded = Net::HTTP.new("four.example")
          bounded.read_timeout = 2 if enabled?
        end
      RUBY
    )

    assert_equal [2, 4], offense_lines(offenses)
  end

  def test_net_http_missing_timeout_correlates_setters_to_each_constructed_client
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          first = Net::HTTP.new("one.example")
          first.read_timeout = 2
          Net::HTTP.new("two.example")
        end
      RUBY
    )

    assert_equal [4], offense_lines(offenses)
  end

  def test_net_http_missing_timeout_accepts_immediate_configuration_blocks
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          Net::HTTP.new("one.example").tap { |http| http.read_timeout = 2 }
          Net::HTTP.new("two.example").then { |http| http.open_timeout = 1 }
        end
      RUBY
    )
  end

  def test_net_http_missing_timeout_bounds_setter_correlation_by_reassignment
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          http = Net::HTTP.new("one.example")
          http = Net::HTTP.new("two.example")
          http.read_timeout = 2
        end
      RUBY
    )

    assert_equal [2], offense_lines(offenses)
  end

  def test_net_http_missing_timeout_rejects_shadowed_block_setters
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def clients
          http = Net::HTTP.new("one.example")
          collection.each { |http| http.read_timeout = 2 }

          Net::HTTP.new("two.example").tap do |client|
            collection.each { |client| client.open_timeout = 1 }
          end
        end
      RUBY
    )

    assert_equal [2, 5], offense_lines(offenses)
  end

  def test_net_http_missing_timeout_documents_wrapper_and_distant_configuration_blind_spots
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      "HttpClient.new(host)\n"
    )

    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::NetHttpMissingTimeout,
      <<~RUBY
        def build
          Net::HTTP.new(host)

          def configure(http)
            http.read_timeout = 5
          end
        end
      RUBY
    )

    assert_equal [2], offense_lines(offenses)
  end

  def test_faraday_missing_timeout_flags_construction_without_call_site_timeout_evidence
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::FaradayMissingTimeout,
      <<~RUBY
        Faraday.new(url)
        Faraday.new(url: url, request: { proxy: proxy })
      RUBY
    )

    assert_equal 2, offenses.size
    assert(offenses.all? { |offense| offense.message.include?("call site") })
  end

  def test_faraday_missing_timeout_accepts_request_hash_or_attached_block_assignment
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::FaradayMissingTimeout,
      <<~RUBY
        Faraday.new(url, request: { timeout: 2 })
        Faraday.new(url, request: { open_timeout: 1 })
        Faraday.new(url) { |connection| connection.options.timeout = 2 }
        Faraday.new(url) { |connection| connection.options.open_timeout = 1 }
        Faraday.new(url) { |connection| connection.options[:timeout] = 2 }
        Faraday.new(url) { |connection| connection.options[:open_timeout] = 1 }
        Faraday.new(url) { _1.options.timeout = 2 }
        Faraday.new(url) { it.options.timeout = 2 }
      RUBY
    )
  end

  def test_faraday_missing_timeout_documents_wrapper_and_global_default_blind_spots
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::FaradayMissingTimeout,
      "HttpClient.new(url)\n"
    )

    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::FaradayMissingTimeout,
      <<~RUBY
        Faraday.default_connection_options = { request: { timeout: 2 } }
        Faraday.new(url)
      RUBY
    )

    assert_equal 1, offenses.size
  end

  def test_httparty_missing_timeout_flags_unconfigured_includes_and_module_calls
    class_offenses = offenses_for(
      RuboCop::Cop::RailsAudit::HttpartyMissingTimeout,
      <<~RUBY
        class Client
          include HTTParty
        end
      RUBY
    )
    call_offenses = offenses_for(
      RuboCop::Cop::RailsAudit::HttpartyMissingTimeout,
      <<~RUBY
        HTTParty.get(url)
        HTTParty.post(url, body: payload)
      RUBY
    )

    assert_equal 1, class_offenses.size
    assert_includes class_offenses.first.message, "class or module body"
    assert_equal 2, call_offenses.size
    assert(call_offenses.all? { |offense| offense.message.include?("call site") })
  end

  def test_httparty_missing_timeout_accepts_timeout_macros_and_call_keywords
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::HttpartyMissingTimeout,
      <<~RUBY
        class DefaultClient
          include HTTParty
          default_timeout 5
        end

        class SplitClient
          include HTTParty
          read_timeout 5
          open_timeout 2
        end

        HTTParty.get(url, timeout: 5)
        HTTParty.delete(url, timeout: 5)
      RUBY
    )
  end

  def test_httparty_missing_timeout_documents_wrapper_and_inherited_configuration_blind_spots
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::HttpartyMissingTimeout,
      "HttpClient.get(url)\n"
    )

    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::HttpartyMissingTimeout,
      <<~RUBY
        class ChildClient < ConfiguredClient
          include HTTParty
        end
      RUBY
    )

    assert_equal 1, offenses.size
  end

  def test_httparty_missing_timeout_ignores_unrelated_timeout_receivers
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::HttpartyMissingTimeout,
      <<~RUBY
        class Client
          include HTTParty
          Configuration.read_timeout
        end
      RUBY
    )

    assert_equal 1, offenses.size
  end

  def test_httparty_missing_timeout_checks_module_bodies_but_not_singleton_classes
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::HttpartyMissingTimeout,
      <<~RUBY
        module ClientMethods
          include HTTParty
        end
      RUBY
    )

    assert_equal [1], offense_lines(offenses)
    assert_includes offenses.first.message, "class or module body"

    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::HttpartyMissingTimeout,
      <<~RUBY
        module ConfiguredClientMethods
          include HTTParty
          default_timeout 5
        end

        class << self
          include HTTParty
        end
      RUBY
    )
  end

  def test_rack_timeout_disabled_flags_literal_disabled_setters_and_middleware_keywords
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::RackTimeoutDisabled,
      <<~RUBY
        Rack::Timeout.service_timeout = 0
        ::Rack::Timeout.service_timeout = false
        config.middleware.use Rack::Timeout, service_timeout: 0
        Rack::Timeout.new(app, service_timeout: false)
      RUBY
    )

    assert_equal 4, offenses.size
    assert(offenses.all? { |offense| offense.message.include?("explicitly disabled") })
  end

  def test_rack_timeout_disabled_ignores_finite_dynamic_and_unrelated_values
    assert_empty offenses_for(
      RuboCop::Cop::RailsAudit::RackTimeoutDisabled,
      <<~RUBY
        Rack::Timeout.service_timeout = 15
        Rack::Timeout.service_timeout = ENV.fetch("SERVICE_TIMEOUT")
        config.middleware.use Rack::Timeout, service_timeout: 10
        OtherMiddleware.new(app, service_timeout: 0)
        settings.service_timeout = false
      RUBY
    )
  end

  def test_rack_timeout_disabled_flags_float_zero
    offenses = offenses_for(
      RuboCop::Cop::RailsAudit::RackTimeoutDisabled,
      <<~RUBY
        Rack::Timeout.service_timeout = 0.0
        config.middleware.use Rack::Timeout, service_timeout: 0.0
      RUBY
    )

    assert_equal [1, 2], offense_lines(offenses)
  end

  private

  def offenses_for(cop_class, source)
    processed_source = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, "/tmp/resilience_test.rb")
    cop = cop_class.new(RuboCop::Config.new, nil)
    commissioner = RuboCop::Cop::Commissioner.new([cop], [], raise_error: true)

    commissioner.investigate(processed_source).offenses
  end

  def offense_lines(offenses)
    offenses.map { |offense| offense.location.line }
  end
end
