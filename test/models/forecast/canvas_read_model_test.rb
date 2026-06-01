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

  test "marks latest run stale when forecast inputs changed after generation" do
    group = build_run_group_with_series(family: @family, user: @user, months: 3)
    event = @family.forecast_events.create!(
      name: "New school cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 1200,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )
    event.update_columns(updated_at: group.finished_at + 1.minute)

    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload

    assert_equal "latest_run", payload.fetch(:source)
    assert_equal true, payload.fetch(:stale)
  end

  test "keeps latest run fresh when forecast inputs are not newer than generation" do
    group = build_run_group_with_series(family: @family, user: @user, months: 3)
    event = @family.forecast_events.create!(
      name: "Known school cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 1200,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )
    event.update_columns(created_at: group.finished_at - 1.minute, updated_at: group.finished_at - 1.minute)

    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload

    assert_equal "latest_run", payload.fetch(:source)
    assert_equal false, payload.fetch(:stale)
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

  test "serializes event window and recurrence details for inspector mode" do
    event = @family.forecast_events.create!(
      name: "School tuition",
      effect_type: "expense",
      behavior: "additive",
      amount: 1200,
      currency: @family.currency,
      starts_on: Date.new(2026, 9, 1),
      ends_on: Date.new(2027, 6, 30),
      recurrence_rule: { "frequency" => "monthly", "interval" => 2, "day_of_month" => 15 },
      status: "planned"
    )

    marker = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).event_marker(event)

    assert_equal "Sep 1, 2026 to Jun 30, 2027", marker.fetch(:window_label)
    assert_equal true, marker.fetch(:recurring)
    assert_equal "Every 2 months on day 15", marker.fetch(:recurrence_label)
    assert_equal({ "frequency" => "monthly", "interval" => 2, "day_of_month" => 15 }, marker.fetch(:recurrence_rule))
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

  test "includes stack inspector metadata and all scenario draft targets" do
    active = @family.forecast_scenarios.create!(name: "Move", status: "active", approval_status: "manual")
    disabled = @family.forecast_scenarios.create!(name: "Pause", status: "disabled", approval_status: "manual")
    group = @family.forecast_run_groups.create!(
      user: @user,
      name: "Manual run",
      run_type: "manual",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: Date.current + 36.months,
      daily_until_on: Date.current + 89.days
    )
    run = group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "move",
      scenario_stack_snapshot: {
        "key" => "move",
        "scenarios" => [
          { "id" => active.id, "name" => active.name },
          { "id" => disabled.id, "name" => disabled.name }
        ]
      },
      status: "running",
      feasibility_status: "warn",
      currency: @family.currency,
      risk_flags: [ { "type" => "negative_cash" } ],
      input_snapshot: forecast_valid_input_snapshot(@family)
    )
    period_start = Date.current
    run.forecast_months.create!(
      period_start_on: period_start,
      period_end_on: period_start.end_of_month,
      precision: "monthly",
      scenario_stack_key: "move",
      currency: @family.currency,
      cash_balance: -100,
      liquid_balance: 500,
      portfolio_value: 1000,
      debt_balance: 200,
      net_worth: 1300,
      risk_flags: []
    )
    run.forecast_goal_evaluations.create!(
      goal_key: "forecast_goal:test",
      scenario_stack_key: "move",
      status: "pass",
      goal_snapshot: { "name" => "Emergency fund" }
    )
    run.update!(status: "completed", finished_at: Time.current)
    group.update!(status: "completed", finished_at: Time.current)

    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload
    stack = payload.fetch(:stacks).find { |candidate| candidate.fetch(:id) == "move" }

    assert_equal [ active.id, disabled.id ].map(&:to_s), stack.fetch(:source_scenario_ids).map(&:to_s)
    assert_equal "warn", stack.fetch(:feasibility_status)
    assert_equal 1, stack.fetch(:goal_status_counts).fetch("pass")
    assert_includes stack.fetch(:risk_flags), "negative_cash"
    assert_includes payload.dig(:draft_options, :scenario_targets).map { |scenario| scenario.fetch(:id) }, disabled.id
  end

  test "includes standard event authoring options for canvas drafts" do
    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload
    options = payload.fetch(:draft_options)

    assert_includes options.fetch(:accounts).map { |account| account.fetch(:id) }, accounts(:depository).id
    assert_includes options.fetch(:categories).map { |category| category.fetch(:id) }, categories(:food_and_drink).id
    assert_equal ForecastEvent::STATUSES, options.fetch(:statuses)
    assert_equal ForecastEvent::AMOUNT_EFFECT_TYPES, options.fetch(:amount_effect_types)
    assert_equal %w[income expense], options.fetch(:category_effect_types)
    assert_equal [ "transfer" ], options.fetch(:transfer_effect_types)
    assert_equal %w[weekly monthly], options.fetch(:recurrence_frequencies)
    assert_equal "__new__", options.fetch(:new_scenario_value)
  end

  test "includes event rail count labels for viewport filtering" do
    labels = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload.fetch(:labels)

    assert_equal "%{count} more in current range", labels.fetch(:event_more_visible)
    assert_equal "%{count} outside visible range", labels.fetch(:event_outside_visible)
  end
end
