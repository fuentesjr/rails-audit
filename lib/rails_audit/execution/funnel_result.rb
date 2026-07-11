# frozen_string_literal: true

module RailsAudit
  module Execution
    STAGE_NAMES = %i[clone_or_copy bundle_install schema_load boot].freeze
    STAGE_STATUSES = %i[
      ok skipped clone_failed install_failed schema_failed boot_failed
      db_adapter_unsupported
    ].freeze

    class StageResult
      attr_reader :name, :status, :duration, :reason

      def initialize(name:, status:, duration:, reason:)
        raise ArgumentError, "unknown funnel stage: #{name}" unless STAGE_NAMES.include?(name)
        raise ArgumentError, "unknown funnel status: #{status}" unless STAGE_STATUSES.include?(status)

        @name = name
        @status = status
        @duration = duration
        @reason = reason
        freeze
      end

      def to_h
        { status: status.to_s, duration:, reason: }
      end
    end

    class FunnelResult
      attr_reader :stages, :versions, :image_ref

      def initialize(stages:, versions:, image_ref:)
        names = stages.map(&:name)
        raise ArgumentError, "funnel stages must be #{STAGE_NAMES.inspect}" unless names == STAGE_NAMES
        validate_flow!(stages)

        @stages = stages.freeze
        @versions = versions.freeze
        @image_ref = image_ref
        freeze
      end

      def outcome
        stages.find { |stage| !%i[ok skipped].include?(stage.status) }&.status || :ok
      end

      def to_h
        {
          outcome: outcome.to_s,
          stages: stages.to_h { |stage| [stage.name, stage.to_h] },
          resolved_versions: versions,
          container_image_ref: image_ref
        }
      end

      private

      def validate_flow!(stages)
        failure_index = stages.index { |stage| !%i[ok skipped].include?(stage.status) }
        if failure_index.nil?
          return if stages.all? { |stage| stage.status == :ok }
        elsif stages.take(failure_index).all? { |stage| stage.status == :ok } &&
              stages.drop(failure_index + 1).all? { |stage| stage.status == :skipped }
          return
        end

        raise ArgumentError, "funnel stages must stop at the first failure"
      end
    end
  end
end
