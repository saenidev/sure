# frozen_string_literal: true

# Write-behind persistence for the forecast save path (plan Amendment A:
# compute-synchronous, persist-async). The assumption update request validates,
# saves the assumption + bumps the plan version in one transaction, renders its
# Turbo Streams from an in-memory RecomputeCoordinator#compute result, then
# enqueues this job AFTER the transaction commits.
#
# The job is an UNCONDITIONAL thin wrapper over the full
# RecomputeCoordinator#recompute: it recomputes the deterministic engine
# off-request and persists under the existing stale-guard/coalescing/replace
# semantics keyed on `against_plan_version`. Out-of-order or duplicate jobs are
# already safe — a stale version writes only a superseded marker, an identical
# key coalesces onto the existing cache. No sync-vs-background decision logic
# lives here.
#
# Failure semantics: the last good cache stays current (the user's screen
# already showed the fresh in-memory result). Sidekiq retries transient
# failures; jobs for deleted plans/snapshots are discarded.
class ForecastProjectionPersistJob < ApplicationJob
  queue_as :high_priority

  discard_on ActiveRecord::RecordNotFound

  def perform(plan_id, source_snapshot_id, against_plan_version, anchor_on = nil)
    plan = Forecasts::Plan.find(plan_id)
    source_snapshot = Forecasts::SourceSnapshot.find(source_snapshot_id)

    Forecasts::Projection::RecomputeCoordinator
      .new(plan: plan, source_snapshot: source_snapshot, anchor_on: anchor_on)
      .recompute(against_plan_version: against_plan_version)
  end
end
