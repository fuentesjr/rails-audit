# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class TimeoutModuleUse < Base
        MSG = "Timeout.timeout interrupts execution at arbitrary points and can corrupt state; " \
              "prefer the library's native timeout options."

        RESTRICT_ON_SEND = %i[timeout].freeze

        def on_send(node)
          return unless node.receiver&.const_type?
          return unless node.receiver.const_name == "Timeout"

          add_offense(node.loc.selector)
        end
      end
    end
  end
end
