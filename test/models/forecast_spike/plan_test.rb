require "test_helper"

# THROWAWAY spike coverage — delete with forecast_hotwire_spike.
class ForecastSpike::PlanTest < ActiveSupport::TestCase
  test "builds a full monthly horizon" do
    plan = ForecastSpike::Plan.new
    assert_equal ForecastSpike::Plan::MONTHS, plan.periods.length
    assert_equal "2026-06", plan.periods.first[:key]
  end

  test "recompute is real: higher salary raises net worth at a later period" do
    low  = ForecastSpike::Plan.new(salary_monthly: 5_000).period(60)[:metrics][:net_worth]
    high = ForecastSpike::Plan.new(salary_monthly: 20_000).period(60)[:metrics][:net_worth]
    assert high > low, "expected higher salary to increase projected net worth"
  end

  test "ignores non-editable / invalid overrides" do
    plan = ForecastSpike::Plan.new(rent_monthly: 99_999, salary_monthly: -5)
    assert_equal ForecastSpike::Plan::DEFAULTS[:rent_monthly], plan.inputs[:rent_monthly]
    assert_equal ForecastSpike::Plan::DEFAULTS[:salary_monthly], plan.inputs[:salary_monthly]
  end
end
