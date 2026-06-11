# frozen_string_literal: true

module Forecasts
  # Drift detection for source-derived assumptions (phase 5). Holds the
  # Scanner plus the cheap staleness key that decides whether a scan is
  # needed at all.
  module Drift
    module_function

    # Composite cache key for a plan's drift state, per the spec: "drift
    # results are cached per family, keyed on (max assumption updated_at,
    # family's latest entry/sync timestamp)".
    #
    # Cost budget — this runs on every workspace GET, so it must stay at
    # "a couple of cheap indexed queries":
    #   - one MAX over the plan's assumptions, scoped by forecast_plan_id
    #     (several forecast_plan_id-prefixed indexes exist; plans hold tens
    #     of rows at most);
    #   - a column read on the already-loaded family row.
    #
    # Family latest-data signal: families.latest_sync_completed_at. Sync
    # touches it whenever any family sync completes (app/models/sync.rb),
    # and the app already uses it as its data-invalidation cache key
    # (Family#build_cache_key, AppCache). Accepted edge: a manual entry edit
    # between syncs does not bump it, so a drift re-scan waits for the next
    # completed sync or any assumption write. entries.maximum(:updated_at)
    # was rejected — entries has no updated_at index, so that MAX would scan
    # every family entry on every GET.
    def scan_key(plan)
      assumptions_max = plan.forecast_assumptions.maximum(:updated_at).to_f
      family_latest = plan.family.latest_sync_completed_at.to_f
      "v1:#{assumptions_max}:#{family_latest}"
    end
  end
end
