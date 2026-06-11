# Phase 5 drift columns. Purely additive: no defaults that rewrite rows, no
# backfill, no index/constraint changes to existing columns.
#
# - forecast_assumptions.drift: the scanner's cached verdict (jsonb, nil when
#   not drifted). Shape documented in Forecasts::Drift::Scanner.
# - forecast_assumptions.drift_silenced_at: "dismiss permanently" — silences
#   drift nudges for this assumption forever.
# - forecast_assumptions.drift_dismissed_amount: soft-dismiss sentinel — the
#   proposed amount the user waved off; the nudge stays hidden while the
#   proposal hasn't moved.
# - forecast_plans.drift_scan_key: the composite staleness key the last scan
#   ran under (see Forecasts::Drift.scan_key).
class AddDriftToForecastAssumptions < ActiveRecord::Migration[7.2]
  def change
    add_column :forecast_assumptions, :drift, :jsonb
    add_column :forecast_assumptions, :drift_silenced_at, :datetime
    add_column :forecast_assumptions, :drift_dismissed_amount, :decimal, precision: 19, scale: 4
    add_column :forecast_plans, :drift_scan_key, :string
  end
end
