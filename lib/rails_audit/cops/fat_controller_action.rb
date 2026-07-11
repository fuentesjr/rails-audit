# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class FatControllerAction < Base
        include DirectMethods

        MSG = "Controller action has %<lines>d body lines (maximum %<max>d)."

        def on_class(node)
          return unless processed_source.file_path.include?("/app/controllers/")
          return unless node.identifier.source.end_with?("Controller")

          each_public_method(node) do |method|
            lines = body_line_count(method)
            next unless lines > cop_config.fetch("MaxLines")

            add_offense(method.loc.name,
                        message: format(MSG, lines: lines, max: cop_config.fetch("MaxLines")))
          end
        end

        private

        def each_public_method(node)
          public_direct_instance_methods(node).each { |method_node| yield method_node }
        end

        # Count the inclusive source span from the first body expression to the last.
        def body_line_count(node)
          body = node.body
          return 0 unless body

          body.last_line - body.first_line + 1
        end

      end
    end
  end
end
