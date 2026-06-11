# frozen_string_literal: true

module Forecasts
  module Projection
    # The result envelope returned by `Forecasts::Projection::Engine.call`. Pure
    # value object, no ActiveRecord. This is the only thing projection cache
    # repositories publish for UI read models. Durable snapshots may store the
    # full packet and result for audit/replay, but first-viewport and
    # selected-period reads use indexed rows or bounded caches. Money is decimal
    # strings plus currency context, never floats. See spec "Engine Contract
    # Envelope" and "Projection Result".
    class Result
      InvalidResultError = Class.new(ArgumentError)

      STATUSES = %w[clean issue_limited blocked].freeze

      attr_reader :schema_version, :engine_version, :input_packet_hash,
        :source_snapshot_hash, :scenario_stack_hash, :plan_version, :status,
        :periods, :series, :traces, :issues, :goals, :summary

      def initialize(attributes)
        attrs = Forecasts::Projection.deep_symbolize(attributes)

        @schema_version = attrs[:schema_version]
        @engine_version = attrs[:engine_version]
        @input_packet_hash = attrs[:input_packet_hash]
        @source_snapshot_hash = attrs[:source_snapshot_hash]
        @scenario_stack_hash = attrs[:scenario_stack_hash]
        @plan_version = attrs[:plan_version]
        @status = attrs[:status]
        @periods = Forecasts::Projection.deep_freeze(Array(attrs[:periods]))
        @series = Forecasts::Projection.deep_freeze(Array(attrs[:series]))
        @goals = Forecasts::Projection.deep_freeze(Array(attrs[:goals]))
        @summary = Forecasts::Projection.deep_freeze(attrs[:summary] || {})
        @traces = coerce_traces(attrs[:traces]).freeze
        @issues = coerce_issues(attrs[:issues]).freeze

        validate!
        freeze
      end

      def to_h
        {
          schema_version: schema_version,
          engine_version: engine_version,
          input_packet_hash: input_packet_hash,
          source_snapshot_hash: source_snapshot_hash,
          scenario_stack_hash: scenario_stack_hash,
          plan_version: plan_version,
          status: status,
          periods: periods,
          series: series,
          traces: traces.map(&:to_h),
          issues: issues.map(&:to_h),
          goals: goals,
          summary: summary
        }
      end

      private
        def coerce_traces(raw)
          Array(raw).map do |trace|
            trace.is_a?(Forecasts::Projection::Trace) ? trace : Forecasts::Projection::Trace.new(trace)
          end
        end

        def coerce_issues(raw)
          Array(raw).map do |issue|
            issue.is_a?(Forecasts::Projection::PlanIssue) ? issue : Forecasts::Projection::PlanIssue.new(issue)
          end
        end

        def validate!
          missing = []
          missing << "schema_version" if schema_version.nil?
          missing << "engine_version" if blank?(engine_version)
          missing << "status" if blank?(status)
          unless missing.empty?
            raise InvalidResultError, "Result missing required fields: #{missing.join(', ')}"
          end

          unless STATUSES.include?(status.to_s)
            raise InvalidResultError,
              "Result status must be one of #{STATUSES.join(', ')} (got #{status.inspect})"
          end
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
    end
  end
end
