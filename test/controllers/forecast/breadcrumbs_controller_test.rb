require "test_helper"

class Forecast::BreadcrumbsControllerTest < ActionDispatch::IntegrationTest
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)

    @family.forecast_events.delete_all
    @family.forecast_goals.delete_all
    @family.forecast_budget_plans.delete_all if @family.respond_to?(:forecast_budget_plans)
    @family.forecast_budget_templates.delete_all if @family.respond_to?(:forecast_budget_templates)
    @family.forecast_budget_overrides.delete_all
    @family.forecast_account_liquidity_settings.delete_all
    @family.forecast_run_groups.delete_all
    @family.forecast_scenarios.delete_all

    @scenario = @family.forecast_scenarios.create!(name: "Move abroad", status: "active", created_by_user: @user)
    @event = @family.forecast_events.create!(
      name: "Relocation cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 5_000,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned",
      forecast_scenario: @scenario
    )
    @goal = @family.forecast_goals.create!(
      name: "Six month runway",
      goal_type: "minimum_cash_runway",
      target_duration_days: 180,
      blocking_behavior: "warn",
      status: "active"
    )
    @liquidity_setting = @family.forecast_account_liquidity_settings.create!(
      account: @account,
      liquidity_class: "cash"
    )
    @budget_override = @family.forecast_budget_overrides.create!(
      period_start_on: Date.current.beginning_of_month,
      override_type: "expected_income",
      amount: 5_000,
      currency: @family.currency,
      status: "active"
    )
    @budget_plan = @family.forecast_budget_plans.create!(
      forecast_scenario: @scenario,
      base_period_start_on: Date.current.beginning_of_month,
      horizon_start_on: Date.current.beginning_of_month,
      horizon_end_on: Date.current.end_of_month + 6.months,
      currency: @family.currency
    )
    sign_in @user
  end

  test "forecast root breadcrumb terminates on forecast" do
    get forecast_path

    assert_response :success
    assert_equal [
      [ "Home", root_path ],
      [ "Forecast", nil ]
    ], @controller.send(:breadcrumbs)
  end

  test "forecast collection subroutes stay nested under forecast" do
    {
      forecast_scenarios_path => "Scenarios",
      forecast_events_path => "Events",
      forecast_goals_path => "Goals",
      forecast_account_liquidity_settings_path => "Account liquidity",
      forecast_budget_plans_path => "Forecast budgets",
      forecast_budget_overrides_path => "Forecast budget",
      forecast_event_links_path => "Reconciliation",
      forecast_templates_path => "Scenario templates",
      forecast_sensitivity_path => "Sensitivity"
    }.each do |path, label|
      get path

      assert_response :success
      assert_equal [
        [ "Home", root_path ],
        [ "Forecast", forecast_path ],
        [ label, nil ]
      ], @controller.send(:breadcrumbs), "expected nested forecast breadcrumbs for #{path}"
    end
  end

  test "forecast new and edit routes include their collection and current form step" do
    {
      new_forecast_scenario_path => [ "Scenarios", forecast_scenarios_path, "New scenario" ],
      edit_forecast_scenario_path(@scenario) => [ "Scenarios", forecast_scenarios_path, "Edit scenario" ],
      new_forecast_event_path => [ "Events", forecast_events_path, "New event" ],
      edit_forecast_event_path(@event) => [ "Events", forecast_events_path, "Edit event" ],
      new_forecast_goal_path => [ "Goals", forecast_goals_path, "New goal" ],
      edit_forecast_goal_path(@goal) => [ "Goals", forecast_goals_path, "Edit goal" ],
      new_forecast_account_liquidity_setting_path(account_id: @account.id) => [ "Account liquidity", forecast_account_liquidity_settings_path, "Override liquidity" ],
      edit_forecast_account_liquidity_setting_path(@liquidity_setting) => [ "Account liquidity", forecast_account_liquidity_settings_path, "Edit liquidity override" ],
      new_forecast_budget_plan_path => [ "Forecast budgets", forecast_budget_plans_path, "New forecast budget" ],
      edit_forecast_budget_plan_path(@budget_plan) => [ "Forecast budgets", forecast_budget_plans_path, "Edit forecast budget" ],
      new_forecast_budget_override_path(override_type: "expected_income") => [ "Forecast budget", forecast_budget_overrides_path, "New budget override" ],
      edit_forecast_budget_override_path(@budget_override) => [ "Forecast budget", forecast_budget_overrides_path, "Edit budget override" ]
    }.each do |path, (collection_label, collection_path, current_label)|
      get path, headers: { "Turbo-Frame" => "modal" }

      assert_response :success
      assert_equal [
        [ "Home", root_path ],
        [ "Forecast", forecast_path ],
        [ collection_label, collection_path ],
        [ current_label, nil ]
      ], @controller.send(:breadcrumbs), "expected form breadcrumbs for #{path}"
    end
  end

  test "forecast review breadcrumb points back through forecast history" do
    run_group = build_completed_run_group(family: @family, user: @user)
    run_group.update_column(:name, "May forecast")

    get forecast_review_path(run_group)

    assert_response :success
    assert_equal [
      [ "Home", root_path ],
      [ "Forecast", forecast_path ],
      [ "History", forecast_path(tab: "history") ],
      [ "May forecast", nil ]
    ], @controller.send(:breadcrumbs)
  end
end
