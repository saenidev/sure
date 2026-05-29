require "test_helper"

class Forecast::PacketBuilderTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
  end

  # --- happy path: all required sections + schema_version --------------------

  test "serializes a completed group into a packet with every required section" do
    group = build_run_group_with_series(family: @family, user: @user)

    packet = Forecast::PacketBuilder.new(group).build

    assert_equal Forecast::PacketBuilder::SCHEMA_VERSION, packet["schema_version"]

    # Required top-level sections (run metadata, currency, balances, monthly
    # budget, recurring, events, debt/savings, portfolio/market, scenarios,
    # risk_flags, questions).
    %w[
      run currency horizon current_balances monthly_budget recurring_summary
      one_time_events debt_assumptions savings_assumptions portfolio_summary
      market_close_summary scenarios risk_flags questions
    ].each do |key|
      assert packet.key?(key), "packet missing #{key} section"
    end

    assert_equal @family.currency, packet["currency"]
    assert_equal group.id, packet["run"]["id"]
    assert_equal "manual", packet["run"]["run_type"]
    assert_equal 36, packet["monthly_budget"].size
    assert packet["questions"].include?("general_recommendations")
    # Day-0 balances come from the first projected day (cash starts at 1000).
    assert_equal "1000.0", packet["current_balances"]["cash_balance"]
  end

  test "monthly budget rows carry income, spending, and balances per month" do
    group = build_run_group_with_series(
      family: @family,
      user: @user,
      month_attrs: ->(i) { { expected_income: 5000, expected_spending: 3000, net_cash_flow: 2000 } }
    )

    packet = Forecast::PacketBuilder.new(group).build
    first_month = packet["monthly_budget"].first

    assert_equal "5000.0", first_month["expected_income"]
    assert_equal "3000.0", first_month["expected_spending"]
    assert_equal "2000.0", first_month["net_cash_flow"]
    assert first_month.key?("categories")
  end

  test "serializes recurring, events, debt, goals, and portfolio from the input snapshot" do
    group = build_completed_run_group(family: @family, user: @user)
    run = group.forecast_runs.first
    snapshot = run.input_snapshot.merge(
      "recurring_items" => [ { "name" => "Rent" } ],
      "recurring_item_count" => 1,
      "forecast_events" => [ { "name" => "Bonus" } ],
      "forecast_event_count" => 1,
      "debt_rows" => [ { "account_id" => "abc" } ],
      "goals" => [ { "name" => "Emergency fund" } ],
      "goal_count" => 1,
      "portfolio" => { "portfolio_value" => "12000.50", "cash_balance" => "500.0", "day_change" => "-15.25", "holdings" => [ {}, {} ], "market_data_quality" => "ok" }
    )
    # Write the richer snapshot while bypassing immutability (completed output);
    # update_column skips callbacks/validations, mirroring a richer real run.
    run.update_column(:input_snapshot, snapshot)

    packet = Forecast::PacketBuilder.new(group.reload).build

    assert_equal 1, packet["recurring_summary"]["count"]
    assert_equal "Rent", packet["recurring_summary"]["items"].first["name"]
    assert_equal "Bonus", packet["one_time_events"].first["name"]
    assert_equal 1, packet["debt_assumptions"]["count"]
    assert_equal 1, packet["savings_assumptions"]["count"]
    assert_equal "12000.5", packet["portfolio_summary"]["portfolio_value"]
    assert_equal 2, packet["portfolio_summary"]["holding_count"]
    assert_equal "ok", packet["portfolio_summary"]["market_data_quality"]

    # The facts warrant deterministic questions for Hermes.
    assert packet["questions"].include?("debt_paydown_optimization")
    assert packet["questions"].include?("goal_feasibility")
  end

  test "scenarios section lists one entry per run including baseline" do
    group = build_completed_run_group(family: @family, user: @user, runs: 2)

    packet = Forecast::PacketBuilder.new(group).build

    assert_equal 2, packet["scenarios"].size
    assert packet["scenarios"].all? { |s| s.key?("scenario_stack_key") && s.key?("feasibility_status") }
  end

  test "risk flags are collapsed to deduped sorted type tokens" do
    group = build_run_group_with_series(family: @family, user: @user)
    group.update_column(:risk_flags, [
      { "type" => "negative_cash" },
      { "type" => "negative_cash" },
      "stale_fx_rate"
    ])

    packet = Forecast::PacketBuilder.new(group.reload).build

    assert_equal %w[negative_cash stale_fx_rate], packet["risk_flags"]
    assert packet["questions"].include?("address_risk_flags")
  end

  test "a projected negative cash month raises the cash runway question" do
    group = build_run_group_with_series(
      family: @family,
      user: @user,
      month_attrs: ->(i) { i.zero? ? { cash_balance: -250 } : {} }
    )

    packet = Forecast::PacketBuilder.new(group).build

    assert packet["questions"].include?("cash_runway_at_risk")
  end

  # --- empty/edge: a bare group still produces a valid packet ----------------

  test "a completed group with no scenarios, events, recurring, or goals still produces a valid packet" do
    # build_completed_run_group uses the minimal empty input snapshot.
    group = build_completed_run_group(family: @family, user: @user)

    packet = Forecast::PacketBuilder.new(group).build

    assert_equal Forecast::PacketBuilder::SCHEMA_VERSION, packet["schema_version"]
    assert_equal [], packet["one_time_events"]
    assert_equal 0, packet["recurring_summary"]["count"]
    assert_equal [], packet["recurring_summary"]["items"]
    assert_equal 0, packet["debt_assumptions"]["count"]
    assert_equal 0, packet["savings_assumptions"]["count"]
    assert_equal [], packet["monthly_budget"]
    assert_equal "0.0", packet["current_balances"]["cash_balance"]
    assert_equal "0.0", packet["portfolio_summary"]["portfolio_value"]
    # Even with nothing to flag, questions is never empty.
    assert_equal [ "general_recommendations" ], packet["questions"]
  end

  # --- failure surfacing: an incomplete group cannot be serialized -----------

  test "building a packet for a non-completed group raises IncompleteRunGroup" do
    group = build_failed_run_group(family: @family, user: @user)

    assert_raises Forecast::PacketBuilder::IncompleteRunGroup do
      Forecast::PacketBuilder.new(group).build
    end
  end
end
