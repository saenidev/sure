# frozen_string_literal: true

require "test_helper"

# Background drift scan: a guarded wrapper over Forecasts::Drift::Scanner.
# Critical behaviors:
#   - stale stored key -> scans (Scanner stores the key it ran under)
#   - stored key already current -> no Scanner work (duplicate enqueues
#     from a burst of stale GETs coalesce on the first performed job)
#   - deleted plan -> discarded, not retried
class ForecastDriftScanJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @as_of = Date.new(2026, 6, 1)
    @plan = Forecasts::Plan.create!(
      family: @family,
      name: "Drift scan plan",
      horizon_start_on: @as_of,
      horizon_end_on: @as_of >> 36,
      reporting_currency: "USD"
    )
    # No linked assumptions in these tests, so Derivation is never asked for
    # proposals — stub construction anyway to keep the boundary closed.
    Forecasts::Derivation.stubs(:new).returns(stub("derivation"))
  end

  test "scans and stores the live key when the stored key is stale" do
    assert_nil @plan.drift_scan_key

    ForecastDriftScanJob.perform_now(@plan.id, "v1:stale:key")

    assert_equal Forecasts::Drift.scan_key(@plan), @plan.reload.drift_scan_key
  end

  test "skips entirely when the stored key is already current" do
    @plan.update_columns(drift_scan_key: Forecasts::Drift.scan_key(@plan))

    Forecasts::Drift::Scanner.expects(:new).never
    ForecastDriftScanJob.perform_now(@plan.id, "v1:any:key")
  end

  test "discards when the plan no longer exists" do
    plan_id = @plan.id
    @plan.destroy!

    assert_nothing_raised do
      ForecastDriftScanJob.perform_now(plan_id, "v1:any:key")
    end
  end
end
