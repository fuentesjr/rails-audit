# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class FaradayMissingTimeout < Base
        REQUEST_TIMEOUTS = %i[timeout open_timeout].freeze
        MSG = "Faraday.new has no timeout visible at this call site or in its attached block; " \
              "set request: { timeout: ..., open_timeout: ... } or an options timeout assignment."

        RESTRICT_ON_SEND = %i[new].freeze

        def on_send(node)
          return unless node.receiver&.const_type?
          return unless node.receiver.const_name == "Faraday"
          return if request_timeout?(node)
          return if attached_block_timeout?(node)

          add_offense(node.loc.selector)
        end

        private

        def request_timeout?(node)
          options = node.arguments.last
          return false unless options&.hash_type?

          request_pair = options.pairs.find do |pair|
            pair.key.sym_type? && pair.key.value == :request
          end
          request = request_pair&.value
          return false unless request&.hash_type?

          request.pairs.any? do |pair|
            pair.key.sym_type? && REQUEST_TIMEOUTS.include?(pair.key.value)
          end
        end

        def attached_block_timeout?(node)
          block = node.parent
          return false unless block&.any_block_type? && block.send_node.equal?(node)

          block.body&.each_node(:send)&.any? { |send| timeout_option_assignment?(send) } || false
        end

        def timeout_option_assignment?(send)
          options = send.receiver
          return false unless options&.send_type? && options.method?(:options)
          return true if %i[timeout= open_timeout=].include?(send.method_name)

          send.method?(:[]=) && send.first_argument&.sym_type? &&
            REQUEST_TIMEOUTS.include?(send.first_argument.value)
        end
      end
    end
  end
end
