require "test_helper"

# THROWAWAY spike coverage — delete with forecast_hotwire_spike.
class ForecastSpike::PlanTest < ActiveSupport::TestCase
  OPENING = { cash: 25_000.0, portfolio: 75_000.0, other_assets: 0.0, debt: 30_000.0 }.freeze
  SEEDS   = { income_monthly: 9_500.0, spending_monthly: 5_200.0, debt_payment_monthly: 600.0 }.freeze

  test "builds a full monthly horizon starting at real opening net worth" do
    plan = ForecastSpike::Plan.new(opening: OPENING, seeds: SEEDS)
    assert_equal ForecastSpike::Plan::MONTHS, plan.periods.length
    assert_equal "2026-06", plan.periods.first[:key]
    assert_equal 70_000, plan.opening_summary[:net_worth] # 25k + 75k + 0 - 30k
  end

  test "recompute is real: higher income raises net worth at a later period" do
    low  = ForecastSpike::Plan.new(opening: OPENING, seeds: SEEDS.merge(income_monthly: 5_000)).period(60)[:metrics][:net_worth]
    high = ForecastSpike::Plan.new(opening: OPENING, seeds: SEEDS.merge(income_monthly: 20_000)).period(60)[:metrics][:net_worth]
    assert high > low, "expected higher income to increase projected net worth"
  end

  test "overrides replace editable seeds but ignore non-editable keys" do
    plan = ForecastSpike::Plan.new(
      opening: OPENING, seeds: SEEDS,
      overrides: { "income_monthly" => 12_000, "cash" => 999, "portfolio_return" => 1 }
    )
    # editable override applied
    assert_equal 12_000, plan.assumption_cards.find { |c| c[:key] == :income_monthly }[:value]
    # non-editable override ignored — opening cash untouched
    assert_equal OPENING[:cash], plan.opening[:cash]
  end
end
