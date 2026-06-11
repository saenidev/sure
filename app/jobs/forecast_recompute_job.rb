# frozen_string_literal: true

# Forecast V2 background recompute job (slice C8).
#
# The over-budget path of the salary save (and later source-refresh / scenario
# edits): when the recompute coordinator reports a plan is too large to recompute
# inline within the interaction budget, the controller commits the edit + bumps
# the plan version synchronously, marks the projection regions "recomputing", and
# hands the projection work here (spec "Live Recompute Model": "enqueues or
# performs recompute for the new version"; "Recompute Job Contract").
#
# Job contract (spec "Recompute Job Contract"):
#   - Keyed by forecast_plan_id, plan_version, scenario_stack_hash,
#     source_snapshot_hash, and engine_version. The controller only knows the plan
#     id + the version it committed for at enqueue time; the snapshot/stack/engine
#     hashes are derived server-side when the job runs (they cannot be trusted from
#     job args anyway). The plan_version is the publish guard.
#   - Reloads the plan through FAMILY-SCOPED ownership (never an unscoped id from
#     job args): the family id is part of the key and the plan is looked up through
#     that family, so a stale/spoofed id finds nothing and the job no-ops.
#   - Publishes ONLY if the plan still exists and no newer plan version has
#     superseded the target cache: the coordinator's `against_plan_version` stale
#     guard writes nothing current and records a superseded marker when the live
#     plan version has already moved past `plan_version`.
#   - Never raises a raw exception into the workspace: a failure is logged with
#     IDs/counts/hashes only (no sensitive financial detail) and swallowed so the
#     job does not retry against an already-superseded version.
class ForecastRecomputeJob < ApplicationJob
  queue_as :medium_priority

  # @param forecast_plan_id [String] the plan to recompute (resolved family-scoped)
  # @param family_id [String] the owning family id (the scope the plan loads through)
  # @param plan_version [Integer] the committed plan version this work targets
  # @param as_of [String, Date, nil] the run/as-of date threaded into the snapshot
  #   builder so nothing downstream reads Date.current. Defaults to today only when
  #   omitted (the controller always threads it).
  def perform(forecast_plan_id:, family_id:, plan_version:, as_of: nil)
    plan = family_scoped_plan(forecast_plan_id, family_id)
    return if plan.nil? # plan gone or family mismatch -> nothing to publish

    # The plan already moved past the version this work targets: do not even build
    # the snapshot. A newer save has its own recompute; this one is superseded.
    return if plan.current_plan_version > plan_version.to_i

    snapshot = Forecasts::SourceSnapshotBuilder.new(
      plan: plan, as_of: resolve_as_of(as_of)
    ).build

    Forecasts::Projection::RecomputeCoordinator.new(
      plan: plan, source_snapshot: snapshot
    ).recompute(against_plan_version: plan_version)
  rescue StandardError => e
    # IDs/counts/hashes only — never financial detail (spec "Sensitive Data In
    # Logs"). Swallow so a now-superseded version does not retry-loop.
    Rails.logger.error(
      "ForecastRecomputeJob failed plan=#{forecast_plan_id} version=#{plan_version}: #{e.class}"
    )
    nil
  end

  private
    # Reloads the plan through the owning family (never an unscoped id from job
    # args). A mismatched/stale id resolves to nil and the job no-ops.
    def family_scoped_plan(plan_id, family_id)
      family = Family.find_by(id: family_id)
      return nil if family.nil?

      family.forecast_plans.find_by(id: plan_id)
    end

    def resolve_as_of(as_of)
      return Date.current if as_of.nil?

      as_of.to_date
    end
end
