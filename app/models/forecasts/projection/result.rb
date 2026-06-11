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
        :periods, :series, :issues, :goals, :summary

      # `presymbolized: true` is an internal fast path for the engine, which
      # builds the envelope from already-symbolized structures — re-walking
      # 361 period rows plus ~9k traces was a measurable slice of the engine
      # perf budget. External callers (raw hashes from JSON, tests) use the
      # default normalizing path.
      #
      # Traces arrive through one of two keys:
      # - `traces:` (legacy/external) — eagerly coerced into Trace value
      #   objects, exactly as before.
      # - `trace_rows:` (engine hot path) — compact TraceRow structs stored
      #   as-is; Trace value objects are only materialized if a consumer asks
      #   for #traces. Building ~9k validated frozen Trace VOs eagerly was the
      #   single largest slice of the <100ms engine budget.
      def initialize(attributes, presymbolized: false)
        attrs = presymbolized ? attributes : Forecasts::Projection.deep_symbolize(attributes)

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
        @trace_rows = attrs[:trace_rows]&.freeze
        @traces = @trace_rows ? nil : coerce_traces(attrs[:traces]).freeze
        @issues = coerce_issues(attrs[:issues]).freeze
        # Mutable cache container created BEFORE freeze: Result is (shallowly)
        # frozen, so lazy memoization mutates this hash's CONTENTS, never an
        # ivar, which is legal under the shallow freeze.
        @lazy = {}

        validate!
        freeze
      end

      # The compact engine trace rows when this result was built via
      # `trace_rows:`, else nil. Persistence consumes these directly — every
      # field reader is identical to Trace's.
      def trace_rows
        @trace_rows
      end

      # Trace value objects. Eager (constructor-coerced) on the legacy `traces:`
      # path; lazily materialized from the compact rows — once, memoized — on
      # the engine path, so callers that never read traces never pay for ~9k
      # value objects.
      def traces
        @traces || @lazy[:traces] ||= materialize_traces
      end

      # `include_traces: false` omits the traces array entirely (without
      # serializing ~9k trace hashes first) for consumers that hash or inspect
      # the envelope minus its largest, fully-derived section.
      def to_h(include_traces: true)
        envelope = {
          schema_version: schema_version,
          engine_version: engine_version,
          input_packet_hash: input_packet_hash,
          source_snapshot_hash: source_snapshot_hash,
          scenario_stack_hash: scenario_stack_hash,
          plan_version: plan_version,
          status: status,
          periods: periods,
          series: series,
          issues: issues.map(&:to_h),
          goals: goals,
          summary: summary
        }
        if include_traces
          # TraceRow#to_h matches Trace#to_h byte-for-byte (same members, same
          # order), so the rows serialize directly without materializing VOs.
          envelope[:traces] = (@trace_rows || traces).map(&:to_h)
        end
        envelope
      end

      private
        def materialize_traces
          @trace_rows.map do |row|
            Forecasts::Projection::Trace.new(row.to_h, presymbolized: true)
          end.freeze
        end

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
