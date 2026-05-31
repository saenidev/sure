require "test_helper"

class Forecast::CanvasReadModelTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    @family.forecast_events.delete_all
    @family.forecast_scenarios.delete_all
  end

  test "returns preview payload when no completed projection exists" do
    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload

    assert_equal "preview", payload.fetch(:source)
    assert payload.fetch(:preview)
    assert payload.fetch(:series).size >= 2
    assert_includes payload.fetch(:metrics).map { |metric| metric.fetch(:key) }, "net_worth"
  end

  test "serializes completed run months into metric series" do
    build_run_group_with_series(family: @family, user: @user, months: 3)

    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload
    baseline = payload.fetch(:series).find { |series| series.fetch(:id) == "baseline" }

    assert_equal "latest_run", payload.fetch(:source)
    assert_equal false, payload.fetch(:preview)
    assert_equal 3, baseline.dig(:metrics, "net_worth").size
    assert_equal "$5,000.00", baseline.dig(:metrics, "net_worth").first.fetch(:formatted)
  end

  test "serializes only current family events" do
    mine = @family.forecast_events.create!(
      name: "Tuition",
      effect_type: "expense",
      behavior: "additive",
      amount: 1200,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )
    families(:empty).forecast_events.create!(
      name: "Foreign",
      effect_type: "income",
      behavior: "additive",
      amount: 1,
      currency: "USD",
      starts_on: Date.current,
      status: "planned"
    )

    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload
    labels = payload.fetch(:events).map { |event| event.fetch(:label) }

    assert_includes labels, mine.name
    assert_not_includes labels, "Foreign"
  end

  test "includes delta from baseline for comparison series points" do
    group = @family.forecast_run_groups.create!(
      user: @user,
      name: "Manual run",
      run_type: "manual",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: Date.current + 36.months,
      daily_until_on: Date.current + 89.days
    )
    baseline = group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: forecast_valid_input_snapshot(@family)
    )
    comparison = group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "move",
      scenario_stack_snapshot: { "key" => "move", "scenarios" => [ { "name" => "Move" } ] },
      status: "running",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: forecast_valid_input_snapshot(@family)
    )
    2.times do |i|
      period_start = Date.current + i.months
      baseline.forecast_months.create!(
        period_start_on: period_start,
        period_end_on: period_start.end_of_month,
        precision: "monthly",
        scenario_stack_key: "baseline",
        currency: @family.currency,
        cash_balance: 1_000 + (i * 100),
        liquid_balance: 2_000 + (i * 100),
        portfolio_value: 0,
        debt_balance: 0,
        net_worth: 5_000 + (i * 100),
        risk_flags: []
      )
      comparison.forecast_months.create!(
        period_start_on: period_start,
        period_end_on: period_start.end_of_month,
        precision: "monthly",
        scenario_stack_key: "move",
        currency: @family.currency,
        cash_balance: 2_000 + (i * 100),
        liquid_balance: 3_000 + (i * 100),
        portfolio_value: 4_000 + (i * 100),
        debt_balance: 0,
        net_worth: 7_000 + (i * 100),
        risk_flags: []
      )
    end
    baseline.update!(status: "completed", finished_at: Time.current)
    comparison.update!(status: "completed", finished_at: Time.current)
    group.update!(status: "completed", finished_at: Time.current)

    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload
    move = payload.fetch(:series).find { |series| series.fetch(:id) == "move" }

    assert_equal 2_000, move.dig(:metrics, "net_worth").first.fetch(:delta_from_baseline)
    assert_equal "$2,000.00", move.dig(:metrics, "net_worth").first.fetch(:formatted_delta)
  end
end
