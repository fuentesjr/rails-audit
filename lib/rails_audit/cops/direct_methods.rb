# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      module DirectMethods
        include VisibilityHelp

        private

        def direct_instance_methods(class_node)
          class_node.each_descendant(:def).select do |method_node|
            directly_owned_by?(method_node, class_node)
          end
        end

        def public_direct_instance_methods(class_node)
          direct_instance_methods(class_node).select { |method_node| node_visibility(method_node) == :public }
        end

        def directly_owned_by?(method_node, class_node)
          method_node.each_ancestor do |ancestor|
            return ancestor.equal?(class_node) if ancestor.class_type?
            return false if ancestor.def_type? || ancestor.defs_type?
          end

          false
        end
      end
    end
  end
end
