require "test_helper"

class Forecast::GoalEvaluatorTest < ActiveSupport::TestCase
  test "required runway goals block scenario feasibility without failing calculation" do
    goal = {
      "id" => SecureRandom.uuid,
      "goal_type" => "minimum_cash_runway",
      "target_duration_days" => 180,
      "required" => true,
      "blocking_behavior" => "blocks_scenario"
    }
    month = Forecast::Engine::MonthRow.new(
      period_start_on: Date.current.beginning_of_month,
      period_end_on: Date.current.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: "USD",
      expected_income: 0,
      expected_spending: 0,
      net_cash_flow: 0,
      cash_balance: 100,
      liquid_balance: 100,
      portfolio_value: 0,
      debt_balance: 0,
      net_worth: 100,
      cash_runway_days: 30,
      liquid_runway_days: 30,
      category_projections: [],
      debt_projections: [],
      source_breakdown: {},
      risk_flags: []
    )

    result = Forecast::GoalEvaluator.new(goals: [ goal ], months: [ month ], scenario_stack_key: "baseline").call

    assert_equal "blocking", result.first.status
  end

  test "target dated goals only evaluate the matching forecast month" do
    target_month_start = Date.current.next_month.beginning_of_month
    goal = {
      "id" => SecureRandom.uuid,
      "goal_type" => "minimum_cash_balance",
      "target_amount" => 1000,
      "target_date" => target_month_start.iso8601,
      "evaluation_starts_on" => target_month_start.iso8601,
      "evaluation_ends_on" => target_month_start.end_of_month.iso8601,
      "required" => true,
      "blocking_behavior" => "blocks_scenario"
    }
    before_target = Forecast::Engine::MonthRow.new(
      period_start_on: Date.current.beginning_of_month,
      period_end_on: Date.current.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: "USD",
      expected_income: 0,
      expected_spending: 0,
      net_cash_flow: 0,
      cash_balance: 100,
      liquid_balance: 100,
      portfolio_value: 0,
      debt_balance: 0,
      net_worth: 100,
      cash_runway_days: 30,
      liquid_runway_days: 30,
      category_projections: [],
      debt_projections: [],
      source_breakdown: {},
      risk_flags: []
    )
    target_month = Forecast::Engine::MonthRow.new(
      period_start_on: target_month_start,
      period_end_on: target_month_start.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: "USD",
      expected_income: 0,
      expected_spending: 0,
      net_cash_flow: 0,
      cash_balance: 1200,
      liquid_balance: 1200,
      portfolio_value: 0,
      debt_balance: 0,
      net_worth: 1200,
      cash_runway_days: 365,
      liquid_runway_days: 365,
      category_projections: [],
      debt_projections: [],
      source_breakdown: {},
      risk_flags: []
    )

    result = Forecast::GoalEvaluator.new(goals: [ goal ], months: [ before_target, target_month ], scenario_stack_key: "baseline").call

    assert_equal "pass", result.first.status
    assert_equal 1, result.first.details.fetch("evaluated_month_count")
    assert_equal target_month.period_end_on, result.first.evaluated_on
  end

  test "required runway goals pass when no month has a finite runway (no projected spend)" do
    goal = {
      "id" => SecureRandom.uuid,
      "goal_type" => "minimum_cash_runway",
      "target_duration_days" => 180,
      "required" => true,
      "blocking_behavior" => "blocks_scenario"
    }
    month = Forecast::Engine::MonthRow.new(
      period_start_on: Date.current.beginning_of_month,
      period_end_on: Date.current.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: "USD",
      expected_income: 0,
      expected_spending: 0,
      net_cash_flow: 0,
      cash_balance: 100,
      liquid_balance: 100,
      portfolio_value: 0,
      debt_balance: 0,
      net_worth: 100,
      cash_runway_days: nil,
      liquid_runway_days: nil,
      category_projections: [],
      debt_projections: [],
      source_breakdown: {},
      risk_flags: []
    )

    result = Forecast::GoalEvaluator.new(goals: [ goal ], months: [ month ], scenario_stack_key: "baseline").call

    assert_equal "pass", result.first.status
    assert_nil result.first.metric_value
    assert_equal "runway_unbounded_no_spend", result.first.details.fetch("reason")
  end

  test "unsupported required blocking goals block until implemented" do
    goal = {
      "id" => SecureRandom.uuid,
      "goal_type" => "debt_payoff",
      "target_amount" => 0,
      "required" => true,
      "blocking_behavior" => "blocks_stack"
    }
    month = Forecast::Engine::MonthRow.new(
      period_start_on: Date.current.beginning_of_month,
      period_end_on: Date.current.end_of_month,
      precision: "daily_backed",
      scenario_stack_key: "baseline",
      currency: "USD",
      expected_income: 0,
      expected_spending: 0,
      net_cash_flow: 0,
      cash_balance: 100,
      liquid_balance: 100,
      portfolio_value: 0,
      debt_balance: 0,
      net_worth: 100,
      cash_runway_days: 30,
      liquid_runway_days: 30,
      category_projections: [],
      debt_projections: [],
      source_breakdown: {},
      risk_flags: []
    )

    result = Forecast::GoalEvaluator.new(goals: [ goal ], months: [ month ], scenario_stack_key: "baseline").call

    assert_equal "blocking", result.first.status
    assert_equal "unsupported_goal_type", result.first.details.fetch("reason")
  end
end
