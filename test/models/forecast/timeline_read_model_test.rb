require "test_helper"

class Forecast::TimelineReadModelTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
  end

  def baseline_run_for(group)
    group.forecast_runs.find { |r| r.scenario_stack_key == "baseline" } || group.forecast_runs.first
  end

  # Adds a category projection + debt projection to the month at `index` of the
  # run (rows are written while the run is non-completed; the helper builds runs
  # in `running` status before flipping, so we must add them before completion).
  # Instead we build a fresh run here so we control completion timing.
  def build_run_with_projections(family:, user:, months: 5, with_debt: true, with_budget: true, scenario_snapshot: nil)
    currency = family.currency
    group = family.forecast_run_groups.create!(
      user: user, name: "Manual run", run_type: "manual", currency: currency,
      horizon_start_on: Date.current, horizon_end_on: Date.current + 36.months,
      daily_until_on: Date.current + 89.days
    )

    run = group.forecast_runs.create!(
      family: family, user: user,
      scenario_stack_key: scenario_snapshot ? scenario_snapshot.fetch("key") : "baseline",
      scenario_stack_snapshot: scenario_snapshot || { "key" => "baseline" },
      status: "running", feasibility_status: "pass", currency: currency,
      input_snapshot: forecast_valid_input_snapshot(family).merge(
        "portfolio" => { "holdings" => [ { "ticker" => "AAPL", "qty" => "10.0", "amount" => "1500.0" } ] }
      )
    )

    90.times do |i|
      run.forecast_days.create!(
        date: Date.current + i.days, scenario_stack_key: "baseline", currency: currency,
        cash_balance: 1000 + (i * 10), liquid_balance: 2000 + (i * 10),
        debt_balance: 0, net_worth: 3000 + (i * 10),
        cash_runway_days: 30, source_breakdown: { "phase" => "daily" }, risk_flags: []
      )
    end

    months.times do |i|
      period_start = Date.current + i.months
      month = run.forecast_months.create!(
        period_start_on: period_start, period_end_on: period_start.end_of_month,
        precision: "monthly", scenario_stack_key: "baseline", currency: currency,
        expected_income: 5000, expected_spending: 3000, net_cash_flow: 2000,
        cash_balance: 1000 + (i * 100), liquid_balance: 2000 + (i * 100),
        portfolio_value: 10000 + (i * 100), debt_balance: with_debt ? 4000 - (i * 100) : 0,
        net_worth: 5000 + (i * 100), cash_runway_days: 30,
        source_breakdown: {
          "budget_income_gap" => "0.0",
          "budget_spend_gap" => "25.0",
          "uncategorized_spending" => "10.0",
          "debt_payment_cash_gap" => "0.0"
        },
        risk_flags: []
      )

      if with_budget
        month.forecast_category_projections.create!(
          projection_key: "cat-#{i}", source: "budget_inheritance", currency: currency,
          budgeted_spending: 500, actual_spending: 100, projected_spending: 300,
          projected_spending_low: 200, projected_spending_expected: 300, projected_spending_high: 400,
          available_to_spend: 200,
          source_snapshot: { "reason" => "budget" },
          source_breakdown: { "budgeted" => "500.0", "applied_spending" => "100.0" },
          risk_flags: []
        )
      end

      if with_debt
        month.forecast_debt_projections.create!(
          projection_key: "debt-#{i}", source: "account_balance_only", currency: currency,
          opening_balance: 4000 - (i * 100), projected_interest: 50, projected_payment: 150,
          cash_payment_gap: 0, projected_drawdown: 0, ending_balance: 4000 - ((i + 1) * 100),
          source_snapshot: { "reason" => "balance" },
          source_breakdown: { "opening_balance" => "#{4000 - (i * 100)}.0" },
          risk_flags: []
        )
      end
    end

    run.update!(status: "completed", finished_at: Time.current)
    group.update!(status: "completed", finished_at: Time.current)
    [ group, run ]
  end

  # --- happy path: all six lanes assemble from a completed run ----------------

  test "assembles all six lanes from a completed run" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 6)
    model = Forecast::TimelineReadModel.new(run)

    assert model.daily_entries.any?, "cash lane (daily) present"
    assert model.monthly_entries.any?, "cash lane (monthly) present"
    assert model.all_monthly_entries.any? { |m| model.budget_rows_for(m).any? }, "budget lane present"
    assert model.portfolio_holdings?, "portfolio lane present"
    assert model.debt_projections?, "debt lane present"
    assert model.goals_lane.is_a?(Array), "goals lane present"
    assert model.baseline?, "scenario lane resolves baseline"
  end

  test "daily cash lane has 90 entries" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 5)
    model = Forecast::TimelineReadModel.new(run)

    assert_equal 90, model.daily_entries.size
  end

  test "monthly cash lane uses the 4-36 window (drops the daily hand-off months)" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 12)
    model = Forecast::TimelineReadModel.new(run)

    # 12 months persisted; the monthly window starts at index 3 -> 9 entries.
    assert_equal 9, model.monthly_entries.size
    # All 36 (here 12) months remain available to the budget/debt/portfolio lanes.
    assert_equal 12, model.all_monthly_entries.size
  end

  test "debt lane reflects forecast_debt_projection rows" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4, with_debt: true)
    model = Forecast::TimelineReadModel.new(run)

    first_month = model.all_monthly_entries.first
    debt_rows = model.debt_rows_for(first_month)

    assert_equal 1, debt_rows.size
    row = debt_rows.first
    assert_equal Money.new(4000, @family.currency), row.opening_balance
    assert_equal Money.new(50, @family.currency), row.projected_interest
    assert_equal Money.new(150, @family.currency), row.projected_payment
    assert_equal Money.new(3900, @family.currency), row.ending_balance
  end

  # --- debt lane: payoff / trend / balloon / refinance / risk flags ----------

  # Builds a completed baseline run whose single month carries one debt
  # projection stamped with the source_snapshot keys + risk_flags the
  # DebtProjectionAdapter normally writes, so we can assert the read model
  # surfaces them without recomputing anything. `month_risk_flags` lets a test
  # stamp the month-level debt_pressures_runway flag.
  def build_run_with_debt_snapshot(family:, user:, debt_source:, debt_source_snapshot:, debt_risk_flags: [], month_risk_flags: [])
    currency = family.currency
    group = family.forecast_run_groups.create!(
      user: user, name: "Manual run", run_type: "manual", currency: currency,
      horizon_start_on: Date.current, horizon_end_on: Date.current + 36.months,
      daily_until_on: Date.current + 89.days
    )
    run = group.forecast_runs.create!(
      family: family, user: user, scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running", feasibility_status: "pass", currency: currency,
      input_snapshot: forecast_valid_input_snapshot(family)
    )
    period_start = Date.current
    month = run.forecast_months.create!(
      period_start_on: period_start, period_end_on: period_start.end_of_month,
      precision: "monthly", scenario_stack_key: "baseline", currency: currency,
      expected_income: 5000, expected_spending: 3000, net_cash_flow: 2000,
      cash_balance: 1000, liquid_balance: 2000, portfolio_value: 0,
      debt_balance: 4000, net_worth: 5000, cash_runway_days: 30,
      source_breakdown: {}, risk_flags: month_risk_flags
    )
    month.forecast_debt_projections.create!(
      projection_key: "Visa", source: debt_source, currency: currency,
      opening_balance: 4000, projected_interest: 50, projected_payment: 150,
      cash_payment_gap: 0, projected_drawdown: 0, ending_balance: 3900,
      source_snapshot: debt_source_snapshot,
      source_breakdown: { "opening_balance" => "4000.0" }, risk_flags: debt_risk_flags
    )
    run.update!(status: "completed", finished_at: Time.current)
    group.update!(status: "completed", finished_at: Time.current)
    [ group, run ]
  end

  test "DebtRow exposes payoff/trend/balloon/refinance/risk_flags from the source_snapshot" do
    _group, run = build_run_with_debt_snapshot(
      family: @family, user: @user, debt_source: "debt_profile_snapshot",
      debt_source_snapshot: {
        "payoff_projected_on" => "2027-03-31",
        "is_payoff_period" => true,
        "balance_trend" => "growing",
        "debt_balloon_due" => { "due_on" => "2026-06-30", "scheduled_balloon_payment" => "1000.0" },
        "refinance" => { "applied" => true, "effective_on" => "2026-09-30" }
      },
      debt_risk_flags: [ { "type" => "debt_balance_growing", "account_id" => 1, "reason" => "interest_exceeds_payment" } ]
    )
    model = Forecast::TimelineReadModel.new(run)
    row = model.debt_rows_for(model.all_monthly_entries.first).first

    assert_equal Date.new(2027, 3, 31), row.payoff_projected_on
    assert row.is_payoff_period
    assert row.payoff?
    assert_equal "growing", row.balance_trend
    assert row.balance_growing?
    assert row.interest_exceeds_payment?
    assert_equal Date.new(2026, 6, 30), row.balloon_due_on
    assert row.balloon_due?
    assert_equal Date.new(2026, 9, 30), row.refinance_effective_on
    assert row.refinance?
    assert_not row.incomplete?
  end

  test "DebtRow returns nil payoff when the snapshot carries no payoff date" do
    _group, run = build_run_with_debt_snapshot(
      family: @family, user: @user, debt_source: "debt_profile_snapshot",
      debt_source_snapshot: {
        "payoff_projected_on" => nil,
        "is_payoff_period" => false,
        "balance_trend" => "amortizing",
        "debt_balloon_due" => {},
        "refinance" => { "applied" => false }
      }
    )
    model = Forecast::TimelineReadModel.new(run)
    row = model.debt_rows_for(model.all_monthly_entries.first).first

    assert_nil row.payoff_projected_on
    assert_not row.payoff?
    assert_not row.is_payoff_period
    assert_nil row.balloon_due_on
    assert_not row.balloon_due?
    assert_nil row.refinance_effective_on
    assert_not row.refinance?
    assert_equal "amortizing", row.balance_trend
  end

  test "debt_pressure? is true only when the month risk_flags include debt_pressures_runway" do
    _group, pressured = build_run_with_debt_snapshot(
      family: @family, user: @user, debt_source: "debt_profile_snapshot",
      debt_source_snapshot: { "balance_trend" => "growing" },
      month_risk_flags: [ { "type" => "debt_pressures_runway", "account_ids" => [ 1 ] } ]
    )
    pressured_model = Forecast::TimelineReadModel.new(pressured)
    assert pressured_model.debt_pressure?(pressured_model.all_monthly_entries.first)

    _group2, calm = build_run_with_debt_snapshot(
      family: @family, user: @user, debt_source: "debt_profile_snapshot",
      debt_source_snapshot: { "balance_trend" => "amortizing" }
    )
    calm_model = Forecast::TimelineReadModel.new(calm)
    assert_not calm_model.debt_pressure?(calm_model.all_monthly_entries.first)
  end

  test "an incomplete account_balance_only row surfaces the caveat and never claims a payoff" do
    _group, run = build_run_with_debt_snapshot(
      family: @family, user: @user, debt_source: "account_balance_only",
      debt_source_snapshot: {
        # Even if a payoff date were somehow present, an incomplete row must not
        # claim it (zero interest is not "fully modeled").
        "payoff_projected_on" => "2027-03-31",
        "is_payoff_period" => true,
        "incomplete_reasons" => [ "auto_accrual_disabled" ]
      },
      debt_risk_flags: [ { "type" => "debt_projection_incomplete", "account_id" => 1, "reason" => "auto_accrual_disabled" } ]
    )
    model = Forecast::TimelineReadModel.new(run)
    row = model.debt_rows_for(model.all_monthly_entries.first).first

    assert row.incomplete?
    assert_not row.payoff?, "an incomplete row must not claim a payoff"
  end

  test "DebtRow tolerates a non-hash / bare-string risk flag without crashing" do
    _group, run = build_run_with_debt_snapshot(
      family: @family, user: @user, debt_source: "account_balance_only",
      debt_source_snapshot: { "balance_trend" => "flat" },
      debt_risk_flags: [ "debt_projection_incomplete" ]
    )
    model = Forecast::TimelineReadModel.new(run)
    row = model.debt_rows_for(model.all_monthly_entries.first).first

    assert row.incomplete?
    assert_equal [ { "type" => "debt_projection_incomplete" } ], row.risk_flags
  end

  test "budget lane reflects forecast_category_projection rows" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4, with_budget: true)
    model = Forecast::TimelineReadModel.new(run)

    rows = model.budget_rows_for(model.all_monthly_entries.first)
    assert_equal 1, rows.size
    row = rows.first
    assert_equal "budget_inheritance", row.source
    assert_equal Money.new(500, @family.currency), row.budgeted
    assert_equal Money.new(300, @family.currency), row.projected
  end

  test "goals lane reflects ForecastGoalEvaluation statuses" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4)
    goal = @family.forecast_goals.create!(name: "Keep cash", goal_type: "minimum_cash_balance", status: "active", target_amount: 2000, currency: @family.currency)
    # Evaluations are not immutable-locked once we add them before any completed
    # parent check; the run is already completed, so create through a fresh
    # association write is blocked. Build the evaluation on a non-completed run.
    run.update_column(:status, "running")
    run.forecast_goal_evaluations.create!(
      forecast_goal: goal, goal_key: "forecast_goal:#{goal.id}",
      scenario_stack_key: "baseline", status: "warn", currency: @family.currency,
      metric_value: 1200, target_value: 2000, evaluated_on: Date.current,
      goal_snapshot: { "name" => "Keep cash" }, details: {}
    )
    run.update_column(:status, "completed")

    model = Forecast::TimelineReadModel.new(run)
    assert_equal 1, model.goals_lane.size
    row = model.goals_lane.first
    assert_equal "warn", row.status
    assert_equal "Keep cash", row.label
    assert_equal Money.new(1200, @family.currency), row.metric_value
  end

  test "scenario lane lists scenarios from scenario_stack_snapshot" do
    snapshot = {
      "key" => "stack1",
      "scenarios" => [
        { "name" => "New job", "starts_on" => "2026-01-01", "ends_on" => nil, "approval_status" => "approved" }
      ]
    }
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4, scenario_snapshot: snapshot)
    model = Forecast::TimelineReadModel.new(run)

    assert_not model.baseline?
    assert_equal 1, model.scenario_lane.size
    assert_equal "New job", model.scenario_lane.first.name
    assert_equal Date.new(2026, 1, 1), model.scenario_lane.first.starts_on
  end

  # --- empty/edge ------------------------------------------------------------

  test "a run with no debt projections renders the debt lane empty (not a crash)" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4, with_debt: false)
    model = Forecast::TimelineReadModel.new(run)

    assert_not model.debt_projections?
    assert model.all_monthly_entries.all? { |m| model.debt_rows_for(m).empty? }
  end

  test "a baseline run with no active scenarios resolves to just baseline" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4)
    model = Forecast::TimelineReadModel.new(run)

    assert model.baseline?
    assert_empty model.scenario_lane
  end

  test "a run with no goal evaluations renders an empty goals lane" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4)
    model = Forecast::TimelineReadModel.new(run)

    assert_not model.goals?
    assert_empty model.goals_lane
  end

  test "a run with no holdings snapshot renders an empty portfolio lane" do
    group = build_completed_run_group(family: @family, user: @user, runs: 1)
    run = baseline_run_for(group)
    model = Forecast::TimelineReadModel.new(run)

    assert_not model.portfolio_holdings?
    assert_empty model.portfolio_holdings
  end

  # --- drilldown -------------------------------------------------------------

  test "a month's drilldown renders humanized source_breakdown rows from persisted JSON" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4)
    model = Forecast::TimelineReadModel.new(run)

    month = model.all_monthly_entries.first
    rows = model.drilldown_rows(month.source_breakdown)

    # Numeric-looking values are wrapped as Money; rows are present and labelled.
    assert rows.any?
    spend_gap = rows.find { |r| r.key == "budget_spend_gap" }
    assert_not_nil spend_gap
    assert_equal Money.new(25, @family.currency), spend_gap.money
  end

  test "drilldown skips nil/blank values and tolerates a non-hash breakdown" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 4)
    model = Forecast::TimelineReadModel.new(run)

    assert_empty model.drilldown_rows(nil)
    assert_empty model.drilldown_rows("not a hash")
    rows = model.drilldown_rows({ "a" => nil, "b" => "", "c" => "5.0" })
    assert_equal [ "c" ], rows.map(&:key)
  end

  # --- no recompute ----------------------------------------------------------

  test "never instantiates Forecast::Engine or InputBuilder (reads persisted rows only)" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 5)

    Forecast::Engine.expects(:new).never
    Forecast::Engine.any_instance.expects(:call).never
    Forecast::InputBuilder.expects(:new).never

    model = Forecast::TimelineReadModel.new(run)
    model.daily_entries
    model.monthly_entries
    model.all_monthly_entries.each do |month|
      model.budget_rows_for(month)
      model.debt_rows_for(month)
    end
    model.goals_lane
    model.scenario_lane
    model.portfolio_holdings
    model.cash_series
    model.portfolio_series
    model.drilldown_rows(model.all_monthly_entries.first.source_breakdown)
  end

  # --- performance: bounded queries (no N+1 over months x projections) -------

  test "assembling all lanes stays within a bounded query count (no N+1)" do
    _group, run = build_run_with_projections(family: @family, user: @user, months: 36)
    model = Forecast::TimelineReadModel.new(run)

    # Days (1) + months (1) + category projections (1) + debt projections (1) +
    # goal evaluations (1, with goal preload) = at most a small constant,
    # independent of the 36 months / their projections.
    assert_queries_count(max: 6) do
      model.daily_entries
      model.monthly_entries
      model.all_monthly_entries.each do |month|
        model.budget_rows_for(month)
        model.debt_rows_for(month)
      end
      model.goals_lane
      model.scenario_lane
      model.portfolio_holdings
    end
  end

  private
    def assert_queries_count(max:)
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) do
        sql = payload[:sql]
        queries << sql if sql && !payload[:name].to_s.include?("SCHEMA") && sql.match?(/SELECT/)
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      assert queries.size <= max, "expected at most #{max} queries, got #{queries.size}:\n#{queries.join("\n")}"
    end
end
