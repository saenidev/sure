require "test_helper"

class ForecastBudgetPlanTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @scenario = @family.forecast_scenarios.create!(
      name: "Remote year",
      status: "active",
      starts_on: Date.current.beginning_of_month.next_month,
      ends_on: Date.current.beginning_of_month.next_month + 11.months
    )
  end

  test "canonicalizes dates and belongs to exactly one scenario" do
    plan = @family.forecast_budget_plans.create!(
      forecast_scenario: @scenario,
      base_period_start_on: Date.current.next_month + 12.days,
      horizon_start_on: Date.current.next_month + 12.days,
      horizon_end_on: Date.current.next_month + 3.months,
      currency: @family.currency
    )

    assert_equal @family.custom_month_start_for(Date.current.next_month + 12.days), plan.base_period_start_on
    assert_equal @scenario.id, plan.forecast_scenario_id

    duplicate = @family.forecast_budget_plans.build(
      forecast_scenario: @scenario,
      base_period_start_on: plan.base_period_start_on,
      horizon_start_on: plan.horizon_start_on,
      horizon_end_on: plan.horizon_end_on,
      currency: @family.currency
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:forecast_scenario_id], "already has a forecast budget plan"
  end

  test "effective amounts use the latest change point at or before the requested month" do
    category = categories(:food_and_drink)
    base_month = @family.custom_month_start_for(Date.current.next_month)
    plan = @family.forecast_budget_plans.create!(
      forecast_scenario: @scenario,
      base_period_start_on: base_month,
      horizon_start_on: base_month,
      horizon_end_on: @family.custom_month_end_for(base_month + 6.months),
      currency: @family.currency
    )
    plan.forecast_budget_plan_amounts.create!(
      family: @family,
      amount_type: "category_spending",
      category: category,
      period_start_on: base_month,
      amount: 700,
      currency: @family.currency
    )
    plan.forecast_budget_plan_amounts.create!(
      family: @family,
      amount_type: "category_spending",
      category: category,
      period_start_on: base_month + 3.months,
      amount: 950,
      currency: @family.currency
    )

    before_change = plan.effective_amounts_for(base_month + 2.months)
    after_change = plan.effective_amounts_for(base_month + 4.months)

    assert_equal 700.to_d, before_change.fetch([ "category_spending", category.id ]).amount
    assert_equal 950.to_d, after_change.fetch([ "category_spending", category.id ]).amount
  end

  test "amount rows reject subcategories and foreign associations" do
    plan = @family.forecast_budget_plans.create!(
      forecast_scenario: @scenario,
      base_period_start_on: Date.current.beginning_of_month.next_month,
      horizon_start_on: Date.current.beginning_of_month.next_month,
      horizon_end_on: Date.current.beginning_of_month.next_month + 3.months,
      currency: @family.currency
    )

    amount = plan.forecast_budget_plan_amounts.build(
      family: @family,
      amount_type: "category_spending",
      category: categories(:subcategory),
      period_start_on: plan.base_period_start_on,
      amount: 100,
      currency: @family.currency
    )

    assert_not amount.valid?
    assert_includes amount.errors[:category], "must be a parent category for forecast budget plans"

    foreign_amount = plan.forecast_budget_plan_amounts.build(
      family: @family,
      amount_type: "category_spending",
      category: families(:empty).categories.create!(name: "Foreign", color: "#0d9488", lucide_icon: "tag"),
      period_start_on: plan.base_period_start_on,
      amount: 100,
      currency: @family.currency
    )

    assert_not foreign_amount.valid?
    assert_includes foreign_amount.errors[:category], "must belong to the forecast family"
  end
end
