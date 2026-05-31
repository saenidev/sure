require "test_helper"

class Forecast::BudgetTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_budget_templates.delete_all if @family.respond_to?(:forecast_budget_templates)
    @family.forecast_budget_plans.delete_all if @family.respond_to?(:forecast_budget_plans)
    @family.forecast_scenarios.delete_all
    @template = @family.forecast_budget_templates.create!(
      name: "Lean template",
      description: "Lower variable spending",
      currency: @family.currency
    )
    sign_in @user
  end

  test "apply creates a disabled scenario-backed plan from the template" do
    @template.forecast_budget_template_amounts.create!(
      family: @family,
      amount_type: "expected_income",
      amount: 6_200,
      currency: @family.currency
    )

    assert_difference "@family.forecast_budget_plans.count", 1 do
      post apply_forecast_budget_template_path(@template)
    end

    plan = @family.forecast_budget_plans.order(:created_at).last
    assert_redirected_to edit_forecast_budget_plan_path(plan)
    assert_equal "disabled", plan.forecast_scenario.status
    assert_equal 6_200.to_d, plan.effective_amounts_for(plan.base_period_start_on).fetch([ "expected_income", nil ]).amount
  end

  test "destroy removes a current-family template" do
    assert_difference "@family.forecast_budget_templates.count", -1 do
      delete forecast_budget_template_path(@template)
    end

    assert_redirected_to forecast_budget_plans_path
  end
end
