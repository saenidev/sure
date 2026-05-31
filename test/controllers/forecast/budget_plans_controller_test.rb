require "test_helper"

class Forecast::BudgetPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_budget_templates.delete_all if @family.respond_to?(:forecast_budget_templates)
    @family.forecast_budget_plans.delete_all if @family.respond_to?(:forecast_budget_plans)
    @family.forecast_scenarios.delete_all
    @category = categories(:food_and_drink)
    sign_in @user
  end

  test "index renders scenario-backed budget plans and templates" do
    plan = create_plan(name: "Lean summer")
    template = @family.forecast_budget_templates.create!(name: "Lean template", currency: @family.currency)

    get forecast_budget_plans_path

    assert_response :success
    assert_select "[data-testid=forecast-budget-plan]", text: /Lean summer/
    assert_select "[data-testid=forecast-budget-template]", text: /Lean template/
    assert_select "a[href=?]", edit_forecast_budget_plan_path(plan)
  end

  test "create builds its own scenario and defaults timeline to next month through forecast horizon" do
    expected_start = @family.current_custom_month_period.start_date + 1.month
    expected_end = Forecast::PeriodBuilder.new(family: @family, start_on: Date.current).call.months.last.end_date

    assert_difference "@family.forecast_scenarios.count", 1 do
      assert_difference "@family.forecast_budget_plans.count", 1 do
        post forecast_budget_plans_path, params: {
          forecast_budget_plan: {
            name: "Move budget",
            description: "Rent doubles and food drops",
            activation_conditions: "Activate if the move scenario is selected",
            depends_on_scenario_ids: [],
            depended_on_by_goal_ids: []
          }
        }
      end
    end

    plan = @family.forecast_budget_plans.order(:created_at).last
    assert_redirected_to edit_forecast_budget_plan_path(plan)
    assert_equal "Move budget", plan.forecast_scenario.name
    assert_equal "Rent doubles and food drops", plan.forecast_scenario.description
    assert_equal expected_start, plan.horizon_start_on
    assert_equal expected_start, plan.base_period_start_on
    assert_equal expected_end, plan.horizon_end_on
    assert_equal "Activate if the move scenario is selected", plan.activation_metadata.fetch("conditions")
  end

  test "update saves plan details and a whole month of amounts without touching real budgets" do
    plan = create_plan
    period = Budget.date_to_param(plan.base_period_start_on)

    assert_no_difference [ "Budget.count", "BudgetCategory.count" ] do
      patch forecast_budget_plan_path(plan, period: period), params: {
        forecast_budget_plan: {
          name: "Updated lean summer",
          description: "Detailed plan",
          status: "active",
          starts_on: plan.horizon_start_on.to_s,
          ends_on: plan.horizon_end_on.to_s,
          base_period_start_on: plan.base_period_start_on.to_s,
          horizon_start_on: plan.horizon_start_on.to_s,
          horizon_end_on: plan.horizon_end_on.to_s,
          activation_conditions: "Only if consulting slows",
          depends_on_scenario_ids: [],
          depended_on_by_scenario_ids: [],
          amounts: {
            "expected_income" => { amount_type: "expected_income", category_id: "", amount: "7200" },
            "uncategorized_spending" => { amount_type: "uncategorized_spending", category_id: "", amount: "300" },
            "category_#{@category.id}" => { amount_type: "category_spending", category_id: @category.id, amount: "650" }
          }
        }
      }
    end

    assert_redirected_to edit_forecast_budget_plan_path(plan, period: period)
    plan.reload
    assert_equal "Updated lean summer", plan.forecast_scenario.name
    assert_equal "Only if consulting slows", plan.activation_metadata.fetch("conditions")
    effective = plan.effective_amounts_for(plan.base_period_start_on)
    assert_equal 7_200.to_d, effective.fetch([ "expected_income", nil ]).amount
    assert_equal 300.to_d, effective.fetch([ "uncategorized_spending", nil ]).amount
    assert_equal 650.to_d, effective.fetch([ "category_spending", @category.id ]).amount
  end

  test "duplicate creates a disabled copy and redirects to its builder" do
    plan = create_plan
    plan.forecast_budget_plan_amounts.create!(
      family: @family,
      amount_type: "expected_income",
      period_start_on: plan.base_period_start_on,
      amount: 6_500,
      currency: @family.currency
    )

    assert_difference "@family.forecast_budget_plans.count", 1 do
      post duplicate_forecast_budget_plan_path(plan)
    end

    copy = @family.forecast_budget_plans.order(:created_at).last
    assert_redirected_to edit_forecast_budget_plan_path(copy)
    assert_equal "disabled", copy.forecast_scenario.status
    assert_equal 6_500.to_d, copy.forecast_budget_plan_amounts.first.amount
  end

  test "create_template captures the current effective month as a reusable template" do
    plan = create_plan
    plan.forecast_budget_plan_amounts.create!(
      family: @family,
      amount_type: "category_spending",
      category: @category,
      period_start_on: plan.base_period_start_on,
      amount: 650,
      currency: @family.currency
    )

    assert_difference "@family.forecast_budget_templates.count", 1 do
      post create_template_forecast_budget_plan_path(plan, period: Budget.date_to_param(plan.base_period_start_on))
    end

    template = @family.forecast_budget_templates.order(:created_at).last
    assert_redirected_to forecast_budget_plans_path
    assert_equal "#{plan.forecast_scenario.name} template", template.name
    assert_equal 650.to_d, template.forecast_budget_template_amounts.first.amount
  end

  private
    def create_plan(name: "Lean summer")
      base_month = @family.current_custom_month_period.start_date + 1.month
      scenario = @family.forecast_scenarios.create!(
        name: name,
        status: "active",
        starts_on: base_month,
        ends_on: @family.custom_month_end_for(base_month + 11.months)
      )
      @family.forecast_budget_plans.create!(
        forecast_scenario: scenario,
        base_period_start_on: base_month,
        horizon_start_on: base_month,
        horizon_end_on: @family.custom_month_end_for(base_month + 11.months),
        currency: @family.currency
      )
    end
end
