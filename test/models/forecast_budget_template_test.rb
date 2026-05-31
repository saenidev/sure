require "test_helper"

class ForecastBudgetTemplateTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  test "applies template into a disabled scenario-backed budget plan" do
    category = categories(:food_and_drink)
    template = @family.forecast_budget_templates.create!(
      name: "Lean month",
      description: "Reduced discretionary spend",
      currency: @family.currency
    )
    template.forecast_budget_template_amounts.create!(
      family: @family,
      amount_type: "expected_income",
      amount: 6_000,
      currency: @family.currency
    )
    template.forecast_budget_template_amounts.create!(
      family: @family,
      amount_type: "category_spending",
      category: category,
      amount: 500,
      currency: @family.currency
    )

    plan = nil
    assert_difference "@family.forecast_scenarios.count", 1 do
      assert_difference "@family.forecast_budget_plans.count", 1 do
        plan = template.apply_to_family!(family: @family, user: @user)
      end
    end

    assert_equal "Lean month", plan.forecast_scenario.name
    assert_equal "disabled", plan.forecast_scenario.status
    assert_equal template.id, plan.source_metadata.fetch("forecast_budget_template_id")
    assert_equal 2, plan.forecast_budget_plan_amounts.count
    assert_equal 6_000.to_d, plan.effective_amounts_for(plan.base_period_start_on).fetch([ "expected_income", nil ]).amount
    assert_equal 500.to_d, plan.effective_amounts_for(plan.base_period_start_on).fetch([ "category_spending", category.id ]).amount
  end
end
