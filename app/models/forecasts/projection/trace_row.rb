# frozen_string_literal: true

module Forecasts
  module Projection
    # Compact engine-internal representation of one explanation trace — the
    # hot-path counterpart of Trace. One row per simulated flow (~9k on a
    # 30-year plan); constructing a validated, frozen Trace value object for
    # each consumed a large slice of the <100ms engine budget, so the engine
    # envelope carries these plain Structs and Result#traces materializes real
    # Trace value objects lazily for consumers that want the validating
    # boundary object.
    #
    # Members mirror Trace's readers exactly (same names, same #to_h shape) so
    # persistence and read-model code can consume either interchangeably.
    TraceRow = Struct.new(
      :id, :period_key, :source_type, :source_id, :assumption_id,
      :scenario_layer_id, :flow_id, :category, :amount, :currency,
      :direction, :display_name, :explanation_key, :source_record_refs
    )
  end
end
