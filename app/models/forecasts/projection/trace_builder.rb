# frozen_string_literal: true

require "digest"

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
      # flow, in the ledger's deterministic order.
      def build
        ledger.flows.map { |flow| trace_for(flow) }
      end

      private
        def trace_for(flow)
          Forecasts::Projection::Trace.new(
            id: trace_id(flow),
            period_key: flow.period_key,
            source_type: "assumption",
            source_id: flow.assumption_id,
            assumption_id: flow.assumption_id,
            scenario_layer_id: flow.scenario_layer_id,
            flow_id: flow.flow_key,
            category: category_for(flow),
            amount: flow.amount,
            currency: flow.currency,
            direction: flow.direction,
            display_name: nil,
            explanation_key: EXPLANATION_KEY_FOR_KIND[flow.source_kind],
            source_record_refs: source_record_refs(flow)
          )
        end

        # Stable trace key: plan version, assumption id, scenario layer, period,
        # and flow key. Hashed so the id stays a short, stable, opaque token.
        def trace_id(flow)
          parts = [
            plan_version,
            flow.assumption_id,
            flow.scenario_layer_id || "baseline",
            flow.period_key,
            flow.flow_key
          ]
          "trace-#{Digest::SHA256.hexdigest(parts.join('|'))[0, 16]}"
        end

        def category_for(flow)
          CATEGORY_FOR_FLOW.fetch(flow.category) do
            raise ArgumentError, "TraceBuilder cannot map flow category #{flow.category.inspect} to a trace category"
          end
        end

        # Source record references behind the value, surfaced as trace metadata so
        # the UI can link to the records without re-querying. For this slice the
        # provenance is the assumption that produced the flow plus any category
        # rollup the expander recorded.
        def source_record_refs(flow)
          refs = [ { type: "assumption", id: flow.assumption_id } ]
          flow.category_ids.each do |category_id|
            refs << { type: "category", id: category_id }
          end
          refs
        end
    end
  end
end
