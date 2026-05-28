require "test_helper"

class ForecastBudgetOverrideTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "category spending override belongs to family category" do
    override = @family.forecast_budget_overrides.build(
      period_start_on: Date.current.beginning_of_month,
      override_type: "category_spending",
      category: categories(:food_and_drink),
      amount: 900,
      currency: @family.currency
    )

    assert override.valid?
  end

  test "income override does not require a category" do
    override = @family.forecast_budget_overrides.build(
      period_start_on: Date.current.beginning_of_month,
      override_type: "expected_income",
      amount: 5000,
      currency: @family.currency
    )

    assert override.valid?
  end

  test "uncategorized spending override does not allow a category" do
    override = @family.forecast_budget_overrides.build(
      period_start_on: Date.current.beginning_of_month,
      override_type: "uncategorized_spending",
      category: categories(:food_and_drink),
      amount: 300,
      currency: @family.currency
    )

    assert_not override.valid?
    assert_includes override.errors[:category], "must be blank unless this is a category spending override"
  end

  test "active overrides are unique per period scenario type and category" do
    period_start = Date.current.beginning_of_month
    @family.forecast_budget_overrides.create!(
      period_start_on: period_start,
      override_type: "expected_income",
      amount: 5000,
      currency: @family.currency
    )
    duplicate = @family.forecast_budget_overrides.build(
      period_start_on: period_start,
      override_type: "expected_income",
      amount: 6000,
      currency: @family.currency
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:base], "active forecast budget override already exists for this period, scenario, type, and category"
  end

  test "category override rejects categories from another family" do
    category = families(:empty).categories.create!(
      name: "Other family spending",
      color: "#0d9488",
      lucide_icon: "tag"
    )
    override = @family.forecast_budget_overrides.build(
      period_start_on: Date.current.beginning_of_month,
      override_type: "category_spending",
      category: category,
      amount: 900,
      currency: @family.currency
    )

    assert_not override.valid?
    assert_includes override.errors[:category], "must belong to the forecast family"
  end

  test "category spending override rejects subcategories" do
    override = @family.forecast_budget_overrides.build(
      period_start_on: Date.current.beginning_of_month,
      override_type: "category_spending",
      category: categories(:subcategory),
      amount: 900,
      currency: @family.currency
    )

    assert_not override.valid?
    assert_includes override.errors[:category], "must be a parent category for forecast budget overrides"
  end

  test "period start is canonicalized to the family custom month period" do
    @family.update!(month_start_day: 15)
    override = @family.forecast_budget_overrides.build(
      period_start_on: Date.new(2026, 5, 1),
      override_type: "expected_income",
      amount: 5000,
      currency: @family.currency
    )

    assert override.valid?
    assert_equal Date.new(2026, 4, 15), override.period_start_on
  end

  test "scenario scoped override must be fully covered by scenario dates" do
    scenario = @family.forecast_scenarios.create!(
      name: "Mid-month move",
      starts_on: Date.current.beginning_of_month + 10.days,
      ends_on: Date.current.end_of_month
    )
    override = @family.forecast_budget_overrides.build(
      forecast_scenario: scenario,
      period_start_on: Date.current.beginning_of_month,
      override_type: "expected_income",
      amount: 5000,
      currency: @family.currency
    )

    assert_not override.valid?
    assert_includes override.errors[:period_start_on], "must be fully covered by the scenario date window"
  end
end
