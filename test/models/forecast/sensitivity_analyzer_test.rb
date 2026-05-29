require "test_helper"

class Forecast::SensitivityAnalyzerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    # All periods live in the future so the engine's monthly branch never nets
    # out "already reflected" actuals, keeping the arithmetic clean and pinned.
    @first_start = Date.current.next_month.beginning_of_month
    @first_end = @first_start.end_of_month
    @second_start = @first_start.next_month
    @second_end = @second_start.end_of_month
    @third_start = @second_start.next_month
    @third_end = @third_start.end_of_month
  end

  test "empty perturbation list returns an empty array" do
    results = Forecast::SensitivityAnalyzer.new(input: base_input, perturbations: []).call

    assert_equal [], results
  end

  test "income -10% lowers end cash and net worth and flips a required cash-balance goal pass -> fail" do
    goal = {
      "id" => "goal-cash-floor",
      "goal_type" => "minimum_cash_balance",
      "target_amount" => 3700.to_d,
      "evaluation_starts_on" => @third_start.iso8601,
      "evaluation_ends_on" => @third_end.iso8601,
      "required" => true,
      "blocking_behavior" => "blocks_scenario"
    }
    input = base_input(goals: [ goal ])

    perturbation = Forecast::SensitivityAnalyzer::Perturbation.new(
      key: "income_minus_10pct", kind: :income, magnitude: -0.10.to_d, description: "Income -10%"
    )
    results = Forecast::SensitivityAnalyzer.new(input: input, perturbations: [ perturbation ]).call

    result = results.first
    assert_equal "income_minus_10pct", result.perturbation_key
    # Baseline ends above the floor (4000); -10% income drains it to 3400, below.
    assert_operator result.baseline_metric.fetch("cash_balance"), :>=, 3700.to_d
    assert_operator result.perturbed_metric.fetch("cash_balance"), :<, 3700.to_d
    assert_operator result.delta.fetch("cash_balance"), :<, 0
    assert_operator result.delta.fetch("net_worth"), :<, 0

    change = result.goal_status_changes.find { |c| c.fetch("forecast_goal_id") == "goal-cash-floor" }
    assert_equal "pass", change.fetch("from")
    assert_equal "blocking", change.fetch("to")
  end

  test "expenses +10% reduces end cash deterministically" do
    input = base_input

    perturbation = Forecast::SensitivityAnalyzer::Perturbation.new(
      key: "expenses_plus_10pct", kind: :expenses, magnitude: 0.10.to_d, description: "Expenses +10%"
    )
    results = Forecast::SensitivityAnalyzer.new(input: input, perturbations: [ perturbation ]).call
    result = results.first

    # 3 months of expenses scaled +10%: each month spends 100 more, over 3 months
    # cash ends 300 lower than baseline (income unchanged).
    assert_equal(-300.to_d, result.delta.fetch("cash_balance"))
    assert_operator result.perturbed_metric.fetch("cash_balance"), :<, result.baseline_metric.fetch("cash_balance")
  end

  test "debt rate +200bps raises end debt balance and projected interest" do
    debt_rows = profile_debt_rows
    input = base_input(debt_rows: debt_rows, accounts: base_accounts + [ debt_account_row ])

    perturbation = Forecast::SensitivityAnalyzer::Perturbation.new(
      key: "debt_rate_plus_200bps", kind: :debt_rate, magnitude: 200.to_d, description: "Debt rate +200bps"
    )
    results = Forecast::SensitivityAnalyzer.new(input: input, perturbations: [ perturbation ]).call
    result = results.first

    assert_operator result.delta.fetch("debt_balance"), :>, 0
    assert_operator result.perturbed_metric.fetch("debt_balance"), :>, result.baseline_metric.fetch("debt_balance")
  end

  test "debt rate +200bps leaves account_balance_only fallback rows untouched while perturbing profile-backed rows" do
    # HARD INVARIANT: balance-only fallback rows never modeled interest, so the
    # rate perturbation must NOT touch them (no phantom interest, no inflated
    # ending balance). This exercises the `next dup unless profile_backed?(row)`
    # guard against an actual fallback row, which the profile-only test above
    # never does.
    profile_row = {
      projection_key: "acct-loan",
      account_id: "acct-loan",
      period_start_on: @first_start,
      period_end_on: @first_end,
      currency: @family.currency,
      opening_balance: 10_000.to_d,
      projected_interest: (10_000.to_d * 0.05.to_d / 12).round(6),
      projected_payment: 0.to_d,
      cash_payment_gap: 0.to_d,
      projected_drawdown: 0.to_d,
      ending_balance: (10_000.to_d + (10_000.to_d * 0.05.to_d / 12).round(6)),
      balance_trend: "growing",
      source: "debt_profile_snapshot",
      risk_flags: [],
      source_snapshot: {}
    }
    fallback_row = {
      projection_key: "acct-fallback",
      account_id: "acct-fallback",
      period_start_on: @first_start,
      period_end_on: @first_end,
      currency: @family.currency,
      opening_balance: 8_000.to_d,
      projected_interest: 0.to_d,
      projected_payment: 0.to_d,
      cash_payment_gap: 0.to_d,
      projected_drawdown: 0.to_d,
      ending_balance: 8_000.to_d,
      balance_trend: "stable",
      source: "account_balance_only",
      risk_flags: [ { "type" => "debt_projection_incomplete", "account_id" => "acct-fallback", "reason" => "missing_terms" } ],
      source_snapshot: {}
    }
    input = base_input(debt_rows: [ profile_row, fallback_row ])

    analyzer = Forecast::SensitivityAnalyzer.new(input: input)
    perturbed_input = analyzer.send(:shift_debt_rate, input, basis_points: 200.to_d)

    perturbed_profile = perturbed_input.debt_rows.find { |row| row.fetch(:account_id) == "acct-loan" }
    perturbed_fallback = perturbed_input.debt_rows.find { |row| row.fetch(:account_id) == "acct-fallback" }

    # Profile-backed row gains the extra interest and a higher ending balance.
    assert_operator perturbed_profile.fetch(:projected_interest), :>, profile_row.fetch(:projected_interest)
    assert_operator perturbed_profile.fetch(:ending_balance), :>, profile_row.fetch(:ending_balance)

    # Balance-only fallback row is byte-for-byte unchanged: no phantom interest,
    # no inflated ending balance, and it still carries its incomplete risk flag.
    assert_equal fallback_row.fetch(:projected_interest), perturbed_fallback.fetch(:projected_interest)
    assert_equal fallback_row.fetch(:ending_balance), perturbed_fallback.fetch(:ending_balance)
    assert_equal fallback_row.fetch(:risk_flags), perturbed_fallback.fetch(:risk_flags)
  end

  test "market return -20% scales portfolio_delta and carries the change into net worth coherently" do
    # A single effect row carrying a positive portfolio_delta with a matching
    # net_worth_delta. Income/expense fields are zero so only the market_return
    # branch moves anything. No debt rows -> debt_balance delta must be 0.
    portfolio_row = {
      id: "portfolio-gain",
      date: @first_start,
      category_id: nil,
      transfer: false,
      transaction_kind: nil,
      budget_flow_type: nil,
      expected_income: 0.to_d,
      expected_spending: 0.to_d,
      cash_delta: 0.to_d,
      liquid_delta: 0.to_d,
      debt_delta: 0.to_d,
      portfolio_delta: 1_000.to_d,
      net_worth_delta: 1_000.to_d,
      risk_flags: [],
      source_snapshot: {}
    }
    input = base_input.with(recurring_items: recurring_rows + [ portfolio_row ])

    perturbation = Forecast::SensitivityAnalyzer::Perturbation.new(
      key: "market_return_minus_20pct", kind: :market_return, magnitude: -0.20.to_d, description: "Market return -20%"
    )
    results = Forecast::SensitivityAnalyzer.new(input: input, perturbations: [ perturbation ]).call
    result = results.first

    assert_equal "market_return_minus_20pct", result.perturbation_key
    # No debt anywhere, so the debt metric is untouched.
    assert_equal 0.to_d, result.delta.fetch("debt_balance")
    # portfolio_delta 1000 -> 800 (factor 0.8); the coherence carry moves
    # net_worth_delta by (800 - 1000) = -200, so the reported net_worth delta is
    # exactly -200. This proves scale_portfolio_rows keeps the net-worth carry in
    # lockstep with the scaled portfolio_delta (the invariant under test).
    assert_equal(-200.to_d, result.delta.fetch("net_worth"))
    # Cash is independent of the portfolio move.
    assert_equal 0.to_d, result.delta.fetch("cash_balance")
  end

  test "a perturbation that does not touch a goal reports no status change for it" do
    # A maximum_debt_balance goal with no debt rows is unaffected by income changes.
    goal = {
      "id" => "goal-debt-cap",
      "goal_type" => "maximum_debt_balance",
      "target_amount" => 1_000_000.to_d,
      "evaluation_starts_on" => @first_start.iso8601,
      "evaluation_ends_on" => @third_end.iso8601,
      "required" => true,
      "blocking_behavior" => "blocks_scenario"
    }
    input = base_input(goals: [ goal ])

    perturbation = Forecast::SensitivityAnalyzer::Perturbation.new(
      key: "income_minus_10pct", kind: :income, magnitude: -0.10.to_d, description: "Income -10%"
    )
    results = Forecast::SensitivityAnalyzer.new(input: input, perturbations: [ perturbation ]).call

    assert_empty results.first.goal_status_changes
  end

  test "the original input is not mutated by a perturbation run" do
    input = base_input

    baseline_before = Forecast::Engine.new(input).call
    cash_before = baseline_before.months.last.cash_balance
    income_rows_before = input.recurring_items.map { |row| row.fetch(:expected_income).to_d }

    Forecast::SensitivityAnalyzer.new(input: input).call

    baseline_after = Forecast::Engine.new(input).call
    income_rows_after = input.recurring_items.map { |row| row.fetch(:expected_income).to_d }

    assert_equal cash_before, baseline_after.months.last.cash_balance
    assert_equal income_rows_before, income_rows_after
  end

  test "identical inputs yield identical results on repeat (deterministic, no RNG)" do
    input = base_input

    first = Forecast::SensitivityAnalyzer.new(input: input).call
    second = Forecast::SensitivityAnalyzer.new(input: input).call

    assert_equal first.map(&:perturbation_key), second.map(&:perturbation_key)
    first.zip(second).each do |a, b|
      assert_equal a.baseline_metric, b.baseline_metric
      assert_equal a.perturbed_metric, b.perturbed_metric
      assert_equal a.delta, b.delta
      assert_equal a.goal_status_changes, b.goal_status_changes
    end
  end

  private
    def base_input(goals: [], debt_rows: [], accounts: base_accounts)
      Forecast::InputBuilder::Result.new(
        family: @family,
        user: @user,
        currency: @family.currency,
        periods: Forecast::PeriodBuilder::Result.new(
          days: [],
          months: [
            Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: @first_start, end_date: @first_end, precision: "monthly"),
            Forecast::PeriodBuilder::PeriodWindow.new(index: 1, start_date: @second_start, end_date: @second_end, precision: "monthly"),
            Forecast::PeriodBuilder::PeriodWindow.new(index: 2, start_date: @third_start, end_date: @third_end, precision: "monthly")
          ]
        ),
        scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
        accounts: accounts,
        budgets: [],
        recurring_items: recurring_rows,
        pending_entries: [],
        portfolio: { portfolio_value: 5_000.to_d, holdings: [], risk_flags: [] },
        debt_rows: debt_rows,
        goals: goals,
        events: [],
        reclassifications: [],
        source_data_versions: {},
        risk_flags: []
      )
    end

    def base_accounts
      [
        {
          id: "acct-cash",
          classification: "asset",
          accountable_type: "Depository",
          liquidity_class: "cash",
          balance: 1_000.to_d,
          risk_flags: [],
          source_snapshot: {}
        }
      ]
    end

    def debt_account_row
      {
        id: "acct-loan",
        classification: "liability",
        accountable_type: "Loan",
        liquidity_class: "debt",
        balance: 10_000.to_d,
        risk_flags: [],
        source_snapshot: {}
      }
    end

    # Income 2000/mo and expense 1000/mo in each of the three months. Net +1000/mo,
    # starting from 1000 cash: end cash baseline = 1000 + 3*1000 = 4000.
    def recurring_rows
      months = [ [ @first_start, @first_end ], [ @second_start, @second_end ], [ @third_start, @third_end ] ]
      months.flat_map do |start_date, _end_date|
        [
          income_row(start_date, 2_000.to_d),
          expense_row(start_date, 1_000.to_d)
        ]
      end
    end

    def income_row(date, amount)
      {
        id: "inc-#{date}",
        date: date,
        category_id: nil,
        transfer: false,
        transaction_kind: nil,
        budget_flow_type: "income",
        expected_income: amount,
        expected_spending: 0.to_d,
        cash_delta: amount,
        liquid_delta: amount,
        debt_delta: 0.to_d,
        portfolio_delta: 0.to_d,
        net_worth_delta: amount,
        risk_flags: [],
        source_snapshot: {}
      }
    end

    def expense_row(date, amount)
      {
        id: "exp-#{date}",
        date: date,
        category_id: nil,
        transfer: false,
        transaction_kind: nil,
        budget_flow_type: "expense",
        expected_income: 0.to_d,
        expected_spending: amount,
        cash_delta: -amount,
        liquid_delta: -amount,
        debt_delta: 0.to_d,
        portfolio_delta: 0.to_d,
        net_worth_delta: -amount,
        risk_flags: [],
        source_snapshot: {}
      }
    end

    # Profile-backed debt rows: opening 10k, modest interest, no payment, so the
    # balance grows. A higher rate must raise end debt balance.
    def profile_debt_rows
      rows = []
      balance = 10_000.to_d
      [ [ @first_start, @first_end ], [ @second_start, @second_end ], [ @third_start, @third_end ] ].each do |start_date, end_date|
        interest = (balance * 0.05.to_d / 12).round(6)
        ending = balance + interest
        rows << {
          projection_key: "acct-loan",
          account_id: "acct-loan",
          period_start_on: start_date,
          period_end_on: end_date,
          currency: @family.currency,
          opening_balance: balance,
          projected_interest: interest,
          projected_payment: 0.to_d,
          cash_payment_gap: 0.to_d,
          projected_drawdown: 0.to_d,
          ending_balance: ending,
          balance_trend: "growing",
          source: "debt_profile_snapshot",
          risk_flags: [],
          source_snapshot: {}
        }
        balance = ending
      end
      rows
    end
end
