# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class FatModel < Base
        include DirectMethods

        MSG = "Model exceeds audit threshold: %<reason>s."

        def on_class(node)
          return unless processed_source.file_path.include?("/app/models/")

          reasons = threshold_reasons(node)
          add_offense(node.identifier, message: format(MSG, reason: reasons.join(" and "))) if reasons.any?
        end

        private

        def threshold_reasons(node)
          reasons = []
          lines = body_line_count(node)
          methods = public_instance_method_count(node)
          reasons << "body has #{lines} lines (maximum #{cop_config.fetch('MaxLines')})" if lines > cop_config.fetch("MaxLines")
          if methods > cop_config.fetch("MaxPublicMethods")
            reasons << "#{methods} public methods (maximum #{cop_config.fetch('MaxPublicMethods')})"
          end
          reasons
        end

        # Count the inclusive source span from the first body expression to the last.
        def body_line_count(node)
          body = node.body
          return 0 unless body

          body.last_line - body.first_line + 1
        end

        def public_instance_method_count(node)
          public_direct_instance_methods(node).size
        end
      end
    end
  end
end
