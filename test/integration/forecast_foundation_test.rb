require "test_helper"

class ForecastFoundationTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    sign_in @user
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
  end

  test "manual scenario run creates explainable forecast output without future budgets" do
    before_budget_count = Budget.count
    budgets(:one).budget_categories.find_or_create_by!(category: categories(:food_and_drink)) do |budget_category|
      budget_category.budgeted_spending = 1200
      budget_category.currency = "USD"
    end

    scenario = @family.forecast_scenarios.create!(
      created_by_user: @user,
      name: "Move country",
      starts_on: 3.months.from_now.to_date,
      position: 1
    )

    @family.forecast_events.create!(
      forecast_scenario: scenario,
      name: "Relocation cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 8000,
      currency: "USD",
      starts_on: 3.months.from_now.to_date
    )

    group = Forecast::Runner.new(
      family: @family,
      user: @user,
      scenario_stacks: [ [], [ scenario.id ] ],
      run_type: "manual",
      name: "Scenario comparison"
    ).call

    assert_equal before_budget_count, Budget.count
    assert_equal "completed", group.status
    assert_equal 2, group.forecast_runs.count

    baseline = group.forecast_runs.find_by!(scenario_stack_key: "baseline")
    assert_equal 90, baseline.forecast_days.count
    assert_equal 36, baseline.forecast_months.count
    assert baseline.forecast_months.order(:period_start_on).first.forecast_category_projections.any?
    assert baseline.input_snapshot.fetch("source_data_versions").present?
  end
end
