# frozen_string_literal: true

require "test_helper"

# Write-behind persist job for the forecast save path (plan Amendment A:
# compute-synchronous, persist-async). The job is a thin wrapper over the full
# RecomputeCoordinator#recompute, so the critical behaviors are:
#   - an enqueued job persists a fresh cache + period rows for the targeted
#     plan version
#   - a stale `against_plan_version` (the plan moved on before the job ran)
#     writes ONLY a superseded marker — never a fresh cache, never period rows
#   - jobs for deleted plans are discarded, not retried
class ForecastProjectionPersistJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @as_of = Date.new(2026, 6, 1)
    @plan = Forecasts::Plan.create!(
      family: @family,
      name: "Persist plan",
      horizon_start_on: @as_of,
      horizon_end_on: @as_of >> 36,
      reporting_currency: "USD"
    )
    @plan.forecast_assumptions.create!(
      family: @family,
      kind: "salary",
      name: "Primary salary",
      status: :active,
      amount: 6000,
      currency: "USD",
      starts_on: @as_of,
      params: { "person_key" => "primary", "frequency" => "monthly", "gross_or_net" => "net" }
    )
    @snapshot = Forecasts::SourceSnapshotBuilder.new(plan: @plan, as_of: @as_of).build
  end

  test "enqueued job persists a fresh cache for the targeted plan version" do
    assert_difference -> { Forecasts::ProjectionCache.count } => 1,
                      -> { Forecasts::ProjectionPeriod.count } => 37 do
      perform_enqueued_jobs do
        ForecastProjectionPersistJob.perform_later(
          @plan.id, @snapshot.id, @plan.current_plan_version, nil
        )
      end
    end

    cache = @plan.forecast_projection_caches.sole
    assert cache.fresh?
    assert_equal @plan.current_plan_version, cache.plan_version
    assert_equal @snapshot.id, cache.forecast_source_snapshot_id
  end

  test "a stale against_plan_version writes only a superseded marker" do
    stale_version = @plan.current_plan_version
    @plan.update!(current_plan_version: stale_version + 1)

    assert_no_difference -> { Forecasts::ProjectionPeriod.count } do
      ForecastProjectionPersistJob.perform_now(@plan.id, @snapshot.id, stale_version, nil)
    end

    marker = @plan.forecast_projection_caches.sole
    assert marker.superseded?
    assert_equal stale_version, marker.plan_version
    assert_equal 0, @plan.forecast_projection_caches.where(status: "fresh").count,
      "a stale job must never publish a fresh cache"
  end

  test "discards when the plan no longer exists" do
    plan_id = @plan.id
    snapshot_id = @snapshot.id
    @plan.destroy!

    assert_nothing_raised do
      ForecastProjectionPersistJob.perform_now(plan_id, snapshot_id, 1, nil)
    end
  end
end
