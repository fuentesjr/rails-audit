# frozen_string_literal: true

module RailsAudit
  module Execution
    STAGE_NAMES = %i[clone_or_copy bundle_install schema_load boot].freeze
    STAGE_STATUSES = %i[
      ok skipped clone_failed install_failed schema_failed boot_failed
      db_adapter_unsupported
    ].freeze
    TOOL_NAMES = %i[active_record_doctor].freeze
    TOOL_STATUSES = %i[skipped clean findings failed].freeze

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

    class ToolRun
      attr_reader :name, :version, :status, :exit_code, :timed_out, :reason

      def initialize(name:, version:, status:, exit_code:, timed_out:, reason:)
        raise ArgumentError, "unknown execution tool: #{name}" unless TOOL_NAMES.include?(name)
        raise ArgumentError, "unknown tool status: #{status}" unless TOOL_STATUSES.include?(status)
        unless reason.is_a?(String)
          raise ArgumentError, "tool run reason must be a string"
        end

        @name = name
        @version = version
        @status = status
        @exit_code = exit_code
        @timed_out = timed_out
        @reason = reason
        freeze
      end

      def failed?
        status == :failed
      end

      def to_h
        { version:, status: status.to_s, exit_code:, timed_out:, reason: }
      end
    end

    class FunnelResult
      attr_reader :stages, :versions, :image_ref, :image_digest, :findings, :tool_runs

      def initialize(stages:, versions:, image_ref:, tool_runs:, image_digest: nil, findings: [])
        names = stages.map(&:name)
        raise ArgumentError, "funnel stages must be #{STAGE_NAMES.inspect}" unless names == STAGE_NAMES
        validate_flow!(stages)
        failure = stages.any? { |stage| !%i[ok skipped].include?(stage.status) }
        raise ArgumentError, "failed funnel cannot carry findings" if failure && findings.any?

        @stages = stages.freeze
        @versions = versions.freeze
        @image_ref = image_ref
        @image_digest = image_digest
        @findings = findings.freeze
        @tool_runs = validated_tool_runs(tool_runs)
        freeze
      end

      def funnel_outcome
        stages.find { |stage| !%i[ok skipped].include?(stage.status) }&.status || :ok
      end

      def outcome
        return funnel_outcome unless funnel_outcome == :ok
        return :tool_failed if tool_runs.values.any?(&:failed?)

        :ok
      end

      def to_h
        {
          outcome: outcome.to_s,
          stages: stages.to_h { |stage| [stage.name, stage.to_h] },
          resolved_versions: versions,
          container_image_ref: image_ref,
          container_image_digest: image_digest,
          tool_runs: tool_runs.transform_values(&:to_h),
          findings: findings.map(&:to_h)
        }
      end

      private

      def validated_tool_runs(runs)
        unless runs.all? { |run| run.instance_of?(ToolRun) }
          raise ArgumentError, "tool runs must be ToolRun values"
        end

        by_name = runs.to_h { |run| [run.name, run] }
        unless by_name.keys.sort == TOOL_NAMES.sort && by_name.size == runs.size
          raise ArgumentError, "tool runs must contain exactly #{TOOL_NAMES.inspect}"
        end
        skipped = by_name.values.map { |run| run.status == :skipped }
        inconsistent = funnel_outcome == :ok ? skipped.any? : !skipped.all?
        if inconsistent
          raise ArgumentError, "tool run status is inconsistent with funnel outcome #{funnel_outcome}"
        end

        by_name.freeze
      end

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
