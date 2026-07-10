# frozen_string_literal: true

require "digest"
require "json"

module RailsAudit
  class Finding
    ATTRIBUTES = %i[
      id native_fingerprint tool rule category impact confidence message location context
    ].freeze

    attr_reader(*ATTRIBUTES)

    def self.identity(tool:, rule:, file:, start_line:, column:, discriminator: "")
      source = [tool, rule, file, start_line, column, discriminator].join("|")
      Digest::SHA256.hexdigest(source)[0, 16]
    end

    def initialize(native_fingerprint:, tool:, rule:, category:, impact:, confidence:, message:,
                   location:, context: nil)
      @native_fingerprint = native_fingerprint
      @tool = tool
      @rule = rule
      @category = category
      @impact = impact
      @confidence = confidence
      @message = message
      @location = immutable_location(location)
      @context = context&.dup&.freeze
      @id = self.class.identity(
        tool: tool,
        rule: rule,
        file: @location.fetch(:file),
        start_line: @location.fetch(:start_line),
        column: @location.fetch(:column)
      )
      freeze
    end

    def to_h
      ATTRIBUTES.to_h { |attribute| [attribute, public_send(attribute)] }
    end

    def to_json(*arguments)
      to_h.to_json(*arguments)
    end

    def ==(other)
      other.instance_of?(self.class) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    private

    def immutable_location(location)
      location.merge(lines: location[:lines]&.dup&.freeze).freeze
    end
  end
end
