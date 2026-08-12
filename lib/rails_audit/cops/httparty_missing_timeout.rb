# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class HttpartyMissingTimeout < Base
        HTTP_METHODS = %i[get post put patch delete head options].freeze
        TIMEOUT_MACROS = %i[default_timeout read_timeout open_timeout].freeze
        CONTAINER_MSG = "HTTParty is included with no default_timeout, read_timeout, or open_timeout visible " \
                        "in this class or module body."
        CALL_MSG = "HTTParty.%<method>s has no timeout set at this call site; pass timeout:."

        RESTRICT_ON_SEND = HTTP_METHODS

        def on_class(node)
          check_container(node)
        end

        def on_module(node)
          check_container(node)
        end

        def on_send(node)
          return unless node.receiver&.const_type?
          return unless node.receiver.const_name == "HTTParty"
          return if timeout_keyword?(node)

          add_offense(node.loc.selector, message: format(CALL_MSG, method: node.method_name))
        end

        private

        def check_container(node)
          sends = container_body_sends(node)
          return unless sends.any? { |send| httparty_include?(send) }
          return if sends.any? do |send|
            send.receiver.nil? && TIMEOUT_MACROS.include?(send.method_name)
          end

          add_offense(node.identifier, message: CONTAINER_MSG)
        end

        def container_body_sends(container_node)
          body = container_node.body
          return [] unless body

          body.each_node(:send).select { |send| belongs_to_container_body?(send, container_node) }
        end

        def belongs_to_container_body?(send, container_node)
          send.each_ancestor do |ancestor|
            return true if ancestor.equal?(container_node)
            return false if ancestor.type?(:def, :defs, :class, :module, :sclass)
          end

          false
        end

        def httparty_include?(send)
          return false unless send.receiver.nil? && send.method?(:include)

          send.arguments.any? do |argument|
            argument.const_type? && argument.const_name == "HTTParty"
          end
        end

        def timeout_keyword?(node)
          options = node.arguments.last
          return false unless options&.hash_type?

          options.pairs.any? { |pair| pair.key.sym_type? && pair.key.value == :timeout }
        end
      end
    end
  end
end
