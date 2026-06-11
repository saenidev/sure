# frozen_string_literal: true

# Background drift scan for a forecast plan (phase 5). Enqueued by
# Forecasts::WorkspaceLoader when the stored drift_scan_key no longer matches
# the live key — the GET path performs only that cheap comparison; ALL
# derivation work happens here (spec §11: no drift computation on GET, ever).
#
# `_scan_key` is the key observed at enqueue time and is informational only
# (call sites keep passing it so it stays visible in job logs/arguments):
# the job re-derives the live key itself and scans under THAT. A burst of
# stale GETs therefore coalesces — the first performed job stores the live
# key (inside Scanner#scan!) and every duplicate no-ops on the guard below;
# a job that raced new data scans under the newest data rather than the
# stale enqueue-time view.
#
# Failure semantics: prior per-assumption drift verdicts stay in place;
# Sidekiq retries transient failures; jobs for deleted plans are discarded.
class ForecastDriftScanJob < ApplicationJob
  queue_as :high_priority

  discard_on ActiveRecord::RecordNotFound

  def perform(plan_id, _scan_key)
    plan = Forecasts::Plan.find(plan_id)

    return if plan.drift_scan_key == Forecasts::Drift.scan_key(plan)

    Forecasts::Drift::Scanner.new(plan: plan, as_of: Date.current).scan!
  end
end
