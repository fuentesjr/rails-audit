# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class NetHttpDefaultTimeouts < Base
        METHODS = %i[get get_response post_form].freeze
        MSG = "Net::HTTP.%<method>s uses fixed 60s defaults and accepts no timeout options at this call site; " \
              "construct Net::HTTP and set its native timeouts."

        RESTRICT_ON_SEND = METHODS

        def on_send(node)
          return unless node.receiver&.const_type?
          return unless node.receiver.const_name == "Net::HTTP"

          add_offense(node.loc.selector, message: format(MSG, method: node.method_name))
        end
      end
    end
  end
end
