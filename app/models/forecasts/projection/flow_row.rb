# frozen_string_literal: true

module Forecasts
  module Projection
    # Compact engine-internal representation of one dated flow — the hot-path
    # counterpart of FlowLedger::Flow. A 30-year x 25-assumption recompute
    # expands ~9k flows; constructing a validated, frozen Flow value object for
    # each consumed roughly half the <100ms engine budget, so the engine
    # pipeline runs on these plain Structs instead. Expanders build them
    # exclusively from already-validated params via the same derivation helpers
    # as Flow (identical keys, ordering, and money strings — the golden fixture
    # pins that equivalence), so per-row validation would re-check literals the
    # expander itself just produced.
    #
    # Duck-type compatible with FlowLedger::Flow for every reader the engine
    # touches (FlowLedger ordering/indexing, PeriodSimulator, TraceBuilder).
    # Anything that needs the validating boundary object (tests, external
    # callers) uses Expanders::Base#expand, which still returns Flow VOs.
    FlowRow = Struct.new(
      :date_iso, :period_key, :amount, :currency, :category, :direction,
      :source_kind, :assumption_id, :scenario_layer_id, :flow_key, :sequence,
      :metadata, :ledger_sort_key
    ) do
      # Living-expense category rollup carried in metadata (mirrors
      # Flow#category_ids).
      def category_ids
        Array(metadata[:category_ids])
      end
    end
  end
end
