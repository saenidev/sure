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
    assert_select "form[action=?]", forecast_budget_plan_path(plan)
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

  test "update with the full editor payload does not materialize unchanged inherited rows" do
    plan = create_plan
    period = Budget.date_to_param(plan.base_period_start_on)

    assert_no_difference "plan.forecast_budget_plan_amounts.count" do
      patch forecast_budget_plan_path(plan, period: period), params: {
        forecast_budget_plan: plan_params(plan).merge(amounts: full_editor_amounts)
      }
    end

    assert_redirected_to edit_forecast_budget_plan_path(plan, period: period)
    assert_empty plan.forecast_budget_plan_amounts.reload
  end

  test "update only saves rows the editor marks as exact changes" do
    plan = create_plan
    period = Budget.date_to_param(plan.base_period_start_on)
    amounts = full_editor_amounts.merge(
      "expected_income" => full_editor_amounts.fetch("expected_income").merge(
        mode: "exact",
        amount: "7250"
      )
    )

    assert_difference "plan.forecast_budget_plan_amounts.count", 1 do
      patch forecast_budget_plan_path(plan, period: period), params: {
        forecast_budget_plan: plan_params(plan).merge(amounts: amounts)
      }
    end

    saved = plan.forecast_budget_plan_amounts.reload.sole
    assert_equal "expected_income", saved.amount_type
    assert_equal 7_250.to_d, saved.amount
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
    assert_equal 650.to_d, template.forecast_budget_template_amounts.find_by!(amount_type: "category_spending", category: @category).amount
  end

  test "update can save a template from the current submitted editor values" do
    plan = create_plan
    period = Budget.date_to_param(plan.base_period_start_on)
    amounts = full_editor_amounts.merge(
      "expected_income" => full_editor_amounts.fetch("expected_income").merge(
        mode: "exact",
        amount: "7600"
      )
    )

    assert_difference "@family.forecast_budget_templates.count", 1 do
      patch forecast_budget_plan_path(plan, period: period), params: {
        commit: I18n.t("forecasts.budget_plans.edit.save_template"),
        forecast_budget_plan: plan_params(plan).merge(amounts: amounts)
      }
    end

    template = @family.forecast_budget_templates.order(:created_at).last
    assert_redirected_to forecast_budget_plans_path
    assert_equal 7_600.to_d, template.forecast_budget_template_amounts.find_by!(amount_type: "expected_income").amount
    assert_equal 7_600.to_d, plan.forecast_budget_plan_amounts.reload.find_by!(amount_type: "expected_income").amount
  end

  test "edit clamps navigation to the plan horizon and names amount controls by row" do
    plan = create_plan
    period = Budget.date_to_param(plan.horizon_start_on)

    get edit_forecast_budget_plan_path(plan, period: period)

    assert_response :success
    assert_select "a[href=?]", edit_forecast_budget_plan_path(plan, period: Budget.date_to_param(plan.horizon_start_on - 1.month)), count: 0
    assert_select "a[href=?]", edit_forecast_budget_plan_path(plan, period: Budget.date_to_param(plan.horizon_start_on + 1.month))
    assert_select "button[form=forecast_budget_plan_form][name=commit][value=save_template]"
    assert_select "label[for=forecast_budget_plan_amount_expected_income]", text: I18n.t("forecasts.budget_plans.editor.forecast_amount_label", label: I18n.t("forecasts.budget_plans.types.expected_income"))
    assert_select "label[for=forecast_budget_plan_amount_slider_expected_income]", text: I18n.t("forecasts.budget_plans.editor.slider_label", label: I18n.t("forecasts.budget_plans.types.expected_income"))
  end

  test "edit gives zero-value rows a slider range beyond one thousand" do
    plan = create_plan
    period = Budget.date_to_param(plan.horizon_start_on)

    get edit_forecast_budget_plan_path(plan, period: period)

    assert_response :success
    fragment = Nokogiri::HTML.fragment(@response.body)
    slider = fragment.at_css("input#forecast_budget_plan_amount_slider_uncategorized_spending")

    assert_not_nil slider
    assert_operator slider["max"].to_d, :>=, 10_000.to_d
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

    def plan_params(plan)
      {
        name: plan.forecast_scenario.name,
        description: plan.forecast_scenario.description,
        status: plan.forecast_scenario.status,
        starts_on: plan.forecast_scenario.starts_on.to_s,
        ends_on: plan.forecast_scenario.ends_on.to_s,
        base_period_start_on: plan.base_period_start_on.to_s,
        horizon_start_on: plan.horizon_start_on.to_s,
        horizon_end_on: plan.horizon_end_on.to_s,
        activation_conditions: "",
        depends_on_scenario_ids: [],
        depended_on_by_scenario_ids: []
      }
    end

    def full_editor_amounts
      {
        "expected_income" => {
          amount_type: "expected_income",
          category_id: "",
          mode: "inherited",
          original_amount: "7000",
          amount: "7000"
        },
        "uncategorized_spending" => {
          amount_type: "uncategorized_spending",
          category_id: "",
          mode: "inherited",
          original_amount: "0",
          amount: "0"
        },
        "category_#{@category.id}" => {
          amount_type: "category_spending",
          category_id: @category.id,
          mode: "inherited",
          original_amount: "500",
          amount: "500"
        }
      }
    end
end
