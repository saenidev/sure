# frozen_string_literal: true

module Forecasts
  module Projection
    # Builds per-flow explanation traces from the simulated flow ledger. The UI
    # and Hermes consume traces instead of reinterpreting raw ledger rows, so the
    # selected-period explanation renders from traces, not chart series.
    #
    # Each flow becomes one Forecasts::Projection::Trace. Trace ids are STABLE
    # keys derived from plan version, assumption id, scenario layer, period, and
    # flow key (spec "Trace Builder": stable trace keys derived from plan version,
    # assumption ID, scenario layer, period, and flow key). The same plan +
    # assumption always yields the same trace id, so caches and patches can target
    # changed regions deterministically.
    #
    # Pure value object: no ActiveRecord, no providers, no clock, no UI string
    # formatting. Money stays a decimal string. This proof slice covers the
    # income and spending flow categories; later flow kinds slot in as their
    # expanders land. See spec "Trace Builder" and "Trace Contract".
    class TraceBuilder
      # Maps a flow ledger category onto the Trace contract category. Income and
      # spending pass straight through for this slice; the catalog grows with
      # later flow kinds.
      CATEGORY_FOR_FLOW = {
        "income" => "income",
        "spending" => "spending"
      }.freeze

      # Stable per-kind explanation locale key. The UI renders this; the builder
      # never formats the string itself.
      EXPLANATION_KEY_FOR_KIND = {
        "salary" => "forecasts.traces.salary",
        "living_expense" => "forecasts.traces.living_expense"
      }.freeze

      attr_reader :ledger, :plan_version

      def initialize(ledger:, plan_version:)
        @ledger = ledger
        @plan_version = plan_version
      end

      # Returns an ordered array of Forecasts::Projection::Trace, one per ledger
      # flow, in the ledger's deterministic order. Materialized from the same
      # rows #build_rows produces, so the two paths cannot drift apart.
      def build
        build_rows.map do |row|
          Forecasts::Projection::Trace.new(row.to_h, presymbolized: true)
        end
      end

      # Returns an ordered array of Forecasts::Projection::TraceRow — the
      # engine's compact hot-path representation (see TraceRow for why). Field
      # values are identical to #build's Trace VOs.
      def build_rows
        ledger.flows.map { |flow| trace_row_for(flow) }
      end

      private
        def trace_row_for(flow)
          Forecasts::Projection::TraceRow.new(
            trace_id(flow),
            flow.period_key,
            "assumption",
            flow.assumption_id,
            flow.assumption_id,
            flow.scenario_layer_id,
            flow.flow_key,
            category_for(flow),
            flow.amount,
            flow.currency,
            flow.direction,
            nil,
            EXPLANATION_KEY_FOR_KIND[flow.source_kind],
            source_record_refs(flow)
          )
        end

        # Stable trace key: plan version, assumption id, scenario layer, period,
        # and flow key — all of which the flow key already embeds (the period is
        # determined by the occurrence date inside it), so the trace id derives
        # directly from it. One trace per flow keeps the mapping injective, and
        # skipping a per-trace SHA256 across ~9k traces on a 30-year plan was a
        # measurable slice of the engine perf budget.
        # Frozen at creation: the ids are shared into the periods' `trace_ids`
        # arrays, and pre-frozen leaves let deep_freeze skip re-walking them.
        def trace_id(flow)
          "trace-#{flow.flow_key}".freeze
        end

        def category_for(flow)
          CATEGORY_FOR_FLOW.fetch(flow.category) do
            raise ArgumentError, "TraceBuilder cannot map flow category #{flow.category.inspect} to a trace category"
          end
        end

        # Source record references behind the value, surfaced as trace metadata so
        # the UI can link to the records without re-querying. For this slice the
        # provenance is the assumption that produced the flow plus any category
        # rollup the expander recorded. Memoized per (assumption, rollup) — the
        # refs are identical for every occurrence of one assumption, so a
        # 361-occurrence expansion shares one frozen array instead of building
        # and freezing 361.
        def source_record_refs(flow)
          # Keyed by assumption id alone: every flow of one assumption carries
          # the same category rollup (expanders build one shared metadata hash
          # per assumption), so the rollup cannot vary within a key.
          @refs_cache ||= {}
          @refs_cache[flow.assumption_id] ||= begin
            refs = [ { type: "assumption", id: flow.assumption_id }.freeze ]
            flow.category_ids.each do |category_id|
              refs << { type: "category", id: category_id }.freeze
            end
            refs.freeze
          end
        end
    end
  end
end
