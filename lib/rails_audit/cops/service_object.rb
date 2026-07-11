# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class ServiceObject < Base
        MSG = "Service object detected; review this architectural pattern."

        def on_class(node)
          return unless processed_source.file_path.include?("/app/services/")
          return unless class_statements(node).any? { |statement| call_method?(statement) }

          add_offense(node.identifier, message: MSG)
        end

        private

        def class_statements(node)
          body = node.body
          return [] unless body

          body.begin_type? ? body.children : [body]
        end

        def call_method?(node)
          return node.method_name == :call if node.def_type?

          node.defs_type? && node.method_name == :call && node.receiver.self_type?
        end
      end
    end
  end
end
