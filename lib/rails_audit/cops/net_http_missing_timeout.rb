# frozen_string_literal: true

module RuboCop
  module Cop
    module RailsAudit
      class NetHttpMissingTimeout < Base
        CONSTRUCTORS = %i[new start].freeze
        TIMEOUT_NAMES = %i[open_timeout read_timeout write_timeout].freeze
        TIMEOUT_SETTERS = TIMEOUT_NAMES.map { |name| :"#{name}=" }.freeze
        CONFIGURATION_BLOCK_METHODS = %i[tap then yield_self].freeze
        ANY_BLOCK_TYPES = %i[block numblock itblock].freeze
        BLOCK_ARGUMENT_TYPES = %i[
          arg optarg restarg kwarg kwoptarg kwrestarg blockarg shadowarg
        ].freeze
        ASSIGNMENT_REFERENCES = {
          lvasgn: :lvar,
          ivasgn: :ivar,
          cvasgn: :cvar,
          gvasgn: :gvar
        }.freeze
        MSG = "Net::HTTP.%<method>s has no open_timeout, read_timeout, or write_timeout visible " \
              "at this call site or in its enclosing method; set Net::HTTP's native timeout options."

        RESTRICT_ON_SEND = CONSTRUCTORS

        def on_send(node)
          return unless node.receiver&.const_type?
          return unless node.receiver.const_name == "Net::HTTP"
          return if node.method?(:start) && timeout_keyword?(node)
          return if timeout_setter_in_enclosing_method?(node)

          add_offense(node.loc.selector, message: format(MSG, method: node.method_name))
        end

        private

        def timeout_keyword?(node)
          options = node.arguments.last
          return false unless options&.hash_type?

          options.pairs.any? do |pair|
            pair.key.sym_type? && TIMEOUT_NAMES.include?(pair.key.value)
          end
        end

        def timeout_setter_in_enclosing_method?(node)
          method_node = node.each_ancestor(:any_def).first
          scope = method_node&.body || processed_source.ast
          return false unless scope

          scope.each_node(:send).any? do |send|
            timeout_setter_send?(send) &&
              send.each_ancestor(:any_def).first.equal?(method_node) &&
              setter_configures_constructor?(send, node, method_node, scope)
          end
        end

        def timeout_setter_send?(send)
          return true if TIMEOUT_SETTERS.include?(send.method_name)

          TIMEOUT_NAMES.include?(send.method_name) && send.parent&.or_asgn_type? &&
            send.parent.children.first.equal?(send)
        end

        def setter_configures_constructor?(setter, constructor, method_node, scope)
          return true if setter.receiver.equal?(constructor)

          binding = constructor_binding(constructor)
          return true if binding && assignment_setter?(setter, binding, method_node, scope)

          block = constructor_configuration_block(constructor)
          block && block_setter?(setter, block)
        end

        def constructor_binding(node)
          direct_binding = binding_for_value(node)
          return direct_binding if direct_binding

          parent = node.parent
          return unless parent&.send_type? && parent.receiver.equal?(node) && parent.method?(:tap)

          block = parent.parent
          return unless block&.any_block_type? && block.send_node.equal?(parent)

          binding_for_value(block)
        end

        def binding_for_value(value)
          parent = value.parent
          if ASSIGNMENT_REFERENCES.key?(parent&.type) && parent.child_nodes.last.equal?(value)
            return [parent, parent]
          end

          return unless parent&.or_asgn_type? && parent.children.last.equal?(value)

          target = parent.children.first
          [target, parent] if ASSIGNMENT_REFERENCES.key?(target.type)
        end

        def assignment_setter?(setter, binding, method_node, scope)
          assignment, expression = binding
          reference_type = ASSIGNMENT_REFERENCES.fetch(assignment.type)
          return false unless reference?(setter.receiver, reference_type, assignment.name)
          return false unless binding_block(assignment, assignment.name)
            .equal?(binding_block(setter, assignment.name))

          setter_position = setter.source_range.begin_pos
          return false if setter_position < expression.source_range.end_pos

          next_assignment = assignment_bindings(scope, method_node)
            .select do |candidate_assignment, candidate_expression|
              candidate_assignment.type == assignment.type &&
                candidate_assignment.name == assignment.name &&
                candidate_expression.source_range.begin_pos > expression.source_range.begin_pos
            end
            .min_by { |_candidate, candidate_expression| candidate_expression.source_range.begin_pos }

          !next_assignment || setter_position < next_assignment.last.source_range.begin_pos
        end

        def assignment_bindings(scope, method_node)
          scope.each_node(*ASSIGNMENT_REFERENCES.keys).filter_map do |assignment|
            next unless assignment.each_ancestor(:any_def).first.equal?(method_node)

            parent = assignment.parent
            if parent&.or_asgn_type? && parent.children.first.equal?(assignment)
              [assignment, parent]
            elsif assignment.children.length > 1
              [assignment, assignment]
            end
          end
        end

        def constructor_configuration_block(node)
          parent = node.parent
          if node.method?(:start) && parent&.any_block_type? && parent.send_node.equal?(node)
            return parent
          end

          chained_send = parent
          return unless chained_send&.send_type? && chained_send.receiver.equal?(node)
          return unless CONFIGURATION_BLOCK_METHODS.include?(chained_send.method_name)

          block = chained_send.parent
          block if block&.any_block_type? && block.send_node.equal?(chained_send)
        end

        def block_setter?(setter, block)
          name = block_reference_name(block)
          return false unless name
          return false unless reference?(setter.receiver, :lvar, name)
          return false unless binding_block(setter, name).equal?(block)

          setter.each_ancestor(*ANY_BLOCK_TYPES).any? { |ancestor| ancestor.equal?(block) }
        end

        def block_reference_name(block)
          case block.type
          when :block
            argument = block.arguments.one? && block.arguments.children.first
            argument.name if argument&.arg_type?
          when :numblock then :_1
          when :itblock then :it
          end
        end

        def binding_block(node, name)
          node.each_ancestor(*ANY_BLOCK_TYPES).find { |block| block_binds_name?(block, name) }
        end

        def block_binds_name?(block, name)
          case block.type
          when :block
            block.arguments.each_node(*BLOCK_ARGUMENT_TYPES).any? do |argument|
              argument.name == name
            end
          when :numblock
            name.to_s.match?(/\A_[1-9]\d*\z/) && name.to_s.delete_prefix("_").to_i <= block.children[1]
          when :itblock
            name == :it
          end
        end

        def reference?(receiver, type, name)
          receiver&.type == type && receiver.children.first == name
        end
      end
    end
  end
end
