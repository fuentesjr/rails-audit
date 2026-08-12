# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class RackTimeoutDisabled < Base
        MSG = "Rack::Timeout service_timeout is explicitly disabled with %<value>s; " \
              "requests can run without a bound. Configure a finite timeout."

        def on_send(node)
          if rack_timeout_setter?(node)
            value = node.first_argument
            add_disabled_offense(value) if disabled_literal?(value)
          elsif rack_timeout_configuration_call?(node)
            pair = service_timeout_pair(node)
            add_disabled_offense(pair.value) if pair && disabled_literal?(pair.value)
          end
        end

        private

        def rack_timeout_setter?(node)
          node.method?(:service_timeout=) && rack_timeout_constant?(node.receiver)
        end

        def rack_timeout_configuration_call?(node)
          rack_timeout_constant?(node.receiver) ||
            node.arguments.any? { |argument| rack_timeout_constant?(argument) }
        end

        def rack_timeout_constant?(node)
          node&.const_type? && node.const_name == "Rack::Timeout"
        end

        def service_timeout_pair(node)
          options = node.arguments.last
          return unless options&.hash_type?

          options.pairs.find do |pair|
            pair.key.sym_type? && pair.key.value == :service_timeout
          end
        end

        def disabled_literal?(node)
          node&.false_type? || (node&.type?(:int, :float) && node.value.zero?)
        end

        def add_disabled_offense(value)
          add_offense(value, message: format(MSG, value: value.source))
        end
      end
    end
  end
end
