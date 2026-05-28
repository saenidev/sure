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

  test "scenario layer adds only its own dated effect and leaves baseline and earlier months untouched" do
    event_on = 3.months.from_now.to_date

    scenario = @family.forecast_scenarios.create!(
      created_by_user: @user,
      name: "Move country",
      starts_on: event_on,
      position: 1
    )

    @family.forecast_events.create!(
      forecast_scenario: scenario,
      name: "Relocation cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 8000,
      currency: "USD",
      starts_on: event_on
    )

    group = Forecast::Runner.new(
      family: @family,
      user: @user,
      scenario_stacks: [ [], [ scenario.id ] ],
      run_type: "manual",
      name: "Scenario comparison"
    ).call

    baseline = group.forecast_runs.find_by!(scenario_stack_key: "baseline")
    scenario_run = group.forecast_runs.find { |run| run.scenario_stack_key != "baseline" }
    assert scenario_run.present?

    baseline_months = baseline.forecast_months.order(:period_start_on).to_a
    scenario_months = scenario_run.forecast_months.order(:period_start_on).to_a

    event_month_index = baseline_months.index { |month| month.period_start_on <= event_on && event_on <= month.period_end_on }
    assert event_month_index.present?, "expected a forecast month containing the scenario event"

    # Months before the scenario event are byte-for-byte identical between the two runs:
    # the scenario layer must not leak into periods it does not touch.
    baseline_months.first(event_month_index).each_with_index do |baseline_month, index|
      scenario_month = scenario_months[index]
      assert_equal baseline_month.cash_balance, scenario_month.cash_balance
      assert_equal baseline_month.net_worth, scenario_month.net_worth
      assert_equal baseline_month.expected_spending, scenario_month.expected_spending
    end

    # The scenario's 8000 expense is fully reflected in the event month relative to baseline.
    baseline_event_month = baseline_months[event_month_index]
    scenario_event_month = scenario_months[event_month_index]
    assert_equal 8000.to_d, scenario_event_month.expected_spending - baseline_event_month.expected_spending
    assert_equal(-8000.to_d, scenario_event_month.cash_balance - baseline_event_month.cash_balance)
    assert_equal(-8000.to_d, scenario_event_month.net_worth - baseline_event_month.net_worth)
  end

  test "toggling one scenario out of a multi-scenario stack removes only that layer's effect" do
    scenario_a_on = 2.months.from_now.to_date
    scenario_b_on = 5.months.from_now.to_date

    scenario_a = @family.forecast_scenarios.create!(
      created_by_user: @user,
      name: "New car",
      starts_on: scenario_a_on,
      position: 1
    )
    @family.forecast_events.create!(
      forecast_scenario: scenario_a,
      name: "Car purchase",
      effect_type: "expense",
      behavior: "additive",
      amount: 3000,
      currency: "USD",
      starts_on: scenario_a_on
    )

    scenario_b = @family.forecast_scenarios.create!(
      created_by_user: @user,
      name: "Move country",
      starts_on: scenario_b_on,
      position: 2
    )
    @family.forecast_events.create!(
      forecast_scenario: scenario_b,
      name: "Relocation cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 8000,
      currency: "USD",
      starts_on: scenario_b_on
    )

    group = Forecast::Runner.new(
      family: @family,
      user: @user,
      scenario_stacks: [ [ scenario_a.id ], [ scenario_a.id, scenario_b.id ] ],
      run_type: "manual",
      name: "Multi-scenario toggle"
    ).call

    a_only_run = group.forecast_runs.find { |run| run.scenario_stack_snapshot.fetch("scenario_ids") == [ scenario_a.id ] }
    a_and_b_run = group.forecast_runs.find { |run| run.scenario_stack_snapshot.fetch("scenario_ids").sort == [ scenario_a.id, scenario_b.id ].sort }
    assert a_only_run.present?
    assert a_and_b_run.present?

    a_only_months = a_only_run.forecast_months.order(:period_start_on).to_a
    a_and_b_months = a_and_b_run.forecast_months.order(:period_start_on).to_a

    b_month_index = a_only_months.index { |month| month.period_start_on <= scenario_b_on && scenario_b_on <= month.period_end_on }
    assert b_month_index.present?

    # Removing scenario B (toggling it off) must leave every month before B's window
    # identical: scenario A's effect is fully preserved and nothing else shifts.
    a_only_months.first(b_month_index).each_with_index do |a_only_month, index|
      a_and_b_month = a_and_b_months[index]
      assert_equal a_only_month.cash_balance, a_and_b_month.cash_balance
      assert_equal a_only_month.net_worth, a_and_b_month.net_worth
      assert_equal a_only_month.expected_spending, a_and_b_month.expected_spending
    end

    # Only scenario B's 8000 delta appears in B's month; A's effect is shared, so the
    # difference between the two stacks is exactly B and nothing else.
    a_only_b_month = a_only_months[b_month_index]
    a_and_b_b_month = a_and_b_months[b_month_index]
    assert_equal 8000.to_d, a_and_b_b_month.expected_spending - a_only_b_month.expected_spending
    assert_equal(-8000.to_d, a_and_b_b_month.cash_balance - a_only_b_month.cash_balance)
  end
end
