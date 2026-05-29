require "test_helper"

class Forecast::EngineTest < ActiveSupport::TestCase
  test "projects monthly budget rows and true net worth" do
    family = families(:dylan_family)
    user = users(:family_admin)
    budgets(:one).budget_categories.find_or_create_by!(category: categories(:food_and_drink)) do |budget_category|
      budget_category.budgeted_spending = 1200
      budget_category.currency = "USD"
    end

    input = Forecast::InputBuilder.new(
      family: family,
      user: user,
      scenario_ids: [],
      start_on: Date.current
    ).call

    result = Forecast::Engine.new(input).call

    assert_equal 90, result.days.size
    assert_equal 36, result.months.size
    assert_equal family.currency, result.days.first.currency
    assert_equal family.currency, result.months.first.currency
    assert result.months.first.net_worth.present?
    assert result.months.first.category_projections.any?
    assert_operator result.months.first.source_breakdown.fetch("actual_spending_already_reflected").to_d, :>, 0
  end

  test "daily backed months carry monthly budget adjustments forward" do
    family = families(:dylan_family)
    user = users(:family_admin)
    first_start = Date.current.beginning_of_month
    first_end = Date.current.end_of_month
    second_start = first_start.next_month
    second_end = second_start.end_of_month
    category_row = {
      category_id: categories(:food_and_drink).id,
      budgeted_spending: 1000.to_d,
      actual_spending: 0.to_d,
      projected_spending_low: 1000.to_d,
      projected_spending_expected: 1000.to_d,
      projected_spending_high: 1000.to_d,
      distribution_source: "test",
      risk_flags: [],
      source_snapshot: {}
    }
    budget_rows = [
      { period_start_on: first_start, expected_income: 0.to_d, actual_income: 0.to_d, source_budget_id: nil, categories: [ category_row ] },
      { period_start_on: second_start, expected_income: 0.to_d, actual_income: 0.to_d, source_budget_id: nil, categories: [ category_row ] }
    ]
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..second_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: first_start, end_date: first_end, precision: "daily_backed"),
          Forecast::PeriodBuilder::PeriodWindow.new(index: 1, start_date: second_start, end_date: second_end, precision: "daily_backed")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 10_000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: budget_rows,
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 9000.to_d, result.months.first.cash_balance
    assert_equal 8000.to_d, result.months.second.cash_balance
  end

  test "partial current period monthly branch does not charge reflected actual spending twice" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current - 10.days
    period_end = Date.current + 10.days
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 10_000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: [
        {
          period_start_on: period_start,
          expected_income: 0.to_d,
          actual_income: 0.to_d,
          source_budget_id: nil,
          categories: [
            {
              category_id: categories(:food_and_drink).id,
              budgeted_spending: 1000.to_d,
              actual_spending: 200.to_d,
              projected_spending_low: 1000.to_d,
              projected_spending_expected: 1000.to_d,
              projected_spending_high: 1000.to_d,
              distribution_source: "test",
              risk_flags: [],
              source_snapshot: {}
            }
          ]
        }
      ],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 9200.to_d, result.months.first.cash_balance
    assert_equal 200.to_d, result.months.first.source_breakdown.fetch("actual_spending_already_reflected").to_d
  end

  test "partial current period monthly branch does not charge reflected uncategorized actual spending twice" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current - 10.days
    period_end = Date.current + 10.days
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 10_000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: [
        {
          period_start_on: period_start,
          expected_income: 0.to_d,
          actual_income: 0.to_d,
          actual_uncategorized_spending: 200.to_d,
          source_budget_id: nil,
          categories: [
            {
              category_id: categories(:food_and_drink).id,
              budgeted_spending: 1000.to_d,
              actual_spending: 0.to_d,
              projected_spending_low: 1000.to_d,
              projected_spending_expected: 1000.to_d,
              projected_spending_high: 1000.to_d,
              distribution_source: "test",
              risk_flags: [],
              source_snapshot: {}
            }
          ]
        }
      ],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 9200.to_d, result.months.first.cash_balance
    assert_equal 200.to_d, result.months.first.source_breakdown.fetch("actual_spending_already_reflected").to_d
  end

  test "runway days include uncategorized budget burn" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 6000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: [
        {
          period_start_on: period_start,
          expected_income: 0.to_d,
          actual_income: 0.to_d,
          budgeted_uncategorized_spending: 3000.to_d,
          actual_uncategorized_spending: 0.to_d,
          source_budget_id: nil,
          categories: []
        }
      ],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 3000.to_d, result.months.first.cash_balance
    assert_equal 30, result.months.first.cash_runway_days
  end

  test "daily backed months do not let uncategorized scenario spending reduce category budget gaps" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "daily_backed")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 10_000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: [
        {
          period_start_on: period_start,
          expected_income: 0.to_d,
          actual_income: 0.to_d,
          source_budget_id: nil,
          categories: [
            {
              category_id: categories(:food_and_drink).id,
              budgeted_spending: 1000.to_d,
              actual_spending: 0.to_d,
              projected_spending_low: 1000.to_d,
              projected_spending_expected: 1000.to_d,
              projected_spending_high: 1000.to_d,
              distribution_source: "test",
              risk_flags: [],
              source_snapshot: {}
            }
          ]
        }
      ],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [
        {
          id: SecureRandom.uuid,
          date: Date.current,
          budget_flow_type: "expense",
          category_id: nil,
          expected_income: 0.to_d,
          expected_spending: 500.to_d,
          cash_delta: -500.to_d,
          liquid_delta: -500.to_d,
          debt_delta: 0.to_d,
          portfolio_delta: 0.to_d,
          net_worth_delta: -500.to_d,
          risk_flags: []
        }
      ],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 1500.to_d, result.months.first.expected_spending
    assert_equal 8500.to_d, result.months.first.cash_balance
    assert_equal 500.to_d, result.months.first.source_breakdown.fetch("uncategorized_spending").to_d
  end

  test "subcategory spending applies to its budgeted parent category projection" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    subcategory = categories(:subcategory)
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "daily_backed")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 10_000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: [
        {
          period_start_on: period_start,
          expected_income: 0.to_d,
          actual_income: 0.to_d,
          source_budget_id: nil,
          categories: [
            {
              category_id: categories(:food_and_drink).id,
              budgeted_spending: 1000.to_d,
              actual_spending: 0.to_d,
              projected_spending_low: 1000.to_d,
              projected_spending_expected: 1000.to_d,
              projected_spending_high: 1000.to_d,
              distribution_source: "test",
              risk_flags: [],
              source_snapshot: {}
            }
          ]
        }
      ],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [
        {
          id: SecureRandom.uuid,
          date: Date.current,
          budget_flow_type: "expense",
          category_id: subcategory.id,
          expected_income: 0.to_d,
          expected_spending: 300.to_d,
          cash_delta: -300.to_d,
          liquid_delta: -300.to_d,
          debt_delta: 0.to_d,
          portfolio_delta: 0.to_d,
          net_worth_delta: -300.to_d,
          risk_flags: []
        }
      ],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call
    parent_projection = result.months.first.category_projections.find { |row| row.fetch(:category_id) == categories(:food_and_drink).id }
    synthetic = result.months.first.category_projections.find { |row| row.fetch(:category_id) == subcategory.id }

    assert_equal 1300.to_d, result.months.first.expected_spending
    assert_equal 8700.to_d, result.months.first.cash_balance
    assert_nil synthetic
    assert_equal "budget_inheritance", parent_projection.fetch(:source)
    assert_equal 300.to_d, parent_projection.fetch(:planned_spending)
  end

  test "categorized spending without a budgeted ancestor becomes a forecast effect projection" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    uncapped_category = categories(:income)
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "daily_backed")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 10_000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: [
        {
          period_start_on: period_start,
          expected_income: 0.to_d,
          actual_income: 0.to_d,
          source_budget_id: nil,
          categories: [
            {
              category_id: categories(:food_and_drink).id,
              budgeted_spending: 1000.to_d,
              actual_spending: 0.to_d,
              projected_spending_low: 1000.to_d,
              projected_spending_expected: 1000.to_d,
              projected_spending_high: 1000.to_d,
              distribution_source: "test",
              risk_flags: [],
              source_snapshot: {}
            }
          ]
        }
      ],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [
        {
          id: SecureRandom.uuid,
          date: Date.current,
          budget_flow_type: "expense",
          category_id: uncapped_category.id,
          expected_income: 0.to_d,
          expected_spending: 300.to_d,
          cash_delta: -300.to_d,
          liquid_delta: -300.to_d,
          debt_delta: 0.to_d,
          portfolio_delta: 0.to_d,
          net_worth_delta: -300.to_d,
          risk_flags: []
        }
      ],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call
    synthetic = result.months.first.category_projections.find { |row| row.fetch(:category_id) == uncapped_category.id }

    assert_equal 1300.to_d, result.months.first.expected_spending
    assert_equal 8700.to_d, result.months.first.cash_balance
    assert_equal "forecast_effect", synthetic.fetch(:source)
    assert_equal "Income", synthetic.fetch(:source_snapshot).fetch("category").fetch("name")
    assert_equal 300.to_d, synthetic.fetch(:planned_spending)
  end

  test "monthly net worth does not double count portfolio accounts classified as cash for liquidity" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "daily_backed")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Investment", liquidity_class: "cash", balance: 10_000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 10_000.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 10_000.to_d, result.months.first.cash_balance
    assert_equal 10_000.to_d, result.months.first.portfolio_value
    assert_equal 10_000.to_d, result.months.first.net_worth
  end

  test "long range months use explicit event net worth deltas for investment contributions" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [ { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 10_000.to_d, risk_flags: [], source_snapshot: {} } ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [
        {
          id: SecureRandom.uuid,
          date: period_start,
          budget_flow_type: "expense",
          category_id: nil,
          expected_income: 0.to_d,
          expected_spending: 1000.to_d,
          cash_delta: -1000.to_d,
          liquid_delta: -1000.to_d,
          debt_delta: 0.to_d,
          portfolio_delta: 1000.to_d,
          net_worth_delta: 0.to_d,
          risk_flags: []
        }
      ],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 9000.to_d, result.months.first.cash_balance
    assert_equal 1000.to_d, result.months.first.portfolio_value
    assert_equal 10_000.to_d, result.months.first.net_worth
  end

  test "debt projection cash payment gaps are net worth neutral when principal falls equally" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 1000.to_d, risk_flags: [], source_snapshot: {} },
        { id: SecureRandom.uuid, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 100.to_d, risk_flags: [] }
      ],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 900.to_d, result.months.first.cash_balance
    assert_equal 900.to_d, result.months.first.debt_balance
    assert_equal 0.to_d, result.months.first.net_worth
  end

  test "budgeted loan payments do not double charge debt projection cash gaps" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    liability_id = SecureRandom.uuid
    loan_category = family.categories.find_or_create_by!(name: "Mortgage") do |category|
      category.color = "#0d9488"
      category.lucide_icon = "house"
    end
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 1000.to_d, risk_flags: [], source_snapshot: {} },
        { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [
        {
          period_start_on: period_start,
          expected_income: 0.to_d,
          actual_income: 0.to_d,
          source_budget_id: nil,
          categories: [
            {
              category_id: loan_category.id,
              budgeted_spending: 100.to_d,
              actual_spending: 0.to_d,
              projected_spending_low: 100.to_d,
              projected_spending_expected: 100.to_d,
              projected_spending_high: 100.to_d,
              distribution_source: "test",
              risk_flags: [],
              source_snapshot: {
                "category" => {
                  "id" => loan_category.id,
                  "name" => loan_category.name,
                  "parent_id" => nil,
                  "parent_name" => nil
                },
                "forecast_budget_override" => {
                  "source_metadata" => {
                    "debt_payment_credit" => true
                  }
                }
              }
            }
          ]
        }
      ],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { account_id: liability_id, period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 100.to_d, risk_flags: [] }
      ],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 900.to_d, result.months.first.cash_balance
    assert_equal 900.to_d, result.months.first.debt_balance
    assert_equal 0.to_d, result.months.first.net_worth
    assert_equal(-100.to_d, result.months.first.net_cash_flow)
    assert_equal 0.to_d, result.months.first.source_breakdown.fetch("budget_spend_gap").to_d
    assert_equal 100.to_d, result.months.first.source_breakdown.fetch("debt_payment_budget_credit").to_d
    assert_equal 0.to_d, result.months.first.source_breakdown.fetch("debt_payment_unbudgeted_cash_gap").to_d
  end

  test "forecast debt payment effects satisfy residual debt cash payment gaps" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    liability_id = accounts(:credit_card).id
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "daily_backed")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 1000.to_d, risk_flags: [], source_snapshot: {} },
        { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { account_id: liability_id, period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 100.to_d, risk_flags: [] }
      ],
      goals: [],
      events: [
        {
          id: SecureRandom.uuid,
          account_id: liability_id,
          destination_account_id: nil,
          date: Date.current,
          budget_flow_type: "expense",
          category_id: nil,
          expected_income: 0.to_d,
          expected_spending: 100.to_d,
          cash_delta: -100.to_d,
          liquid_delta: -100.to_d,
          debt_delta: -100.to_d,
          portfolio_delta: 0.to_d,
          net_worth_delta: 0.to_d,
          risk_flags: []
        }
      ],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 900.to_d, result.months.first.cash_balance
    assert_equal 900.to_d, result.months.first.debt_balance
    assert_equal 0.to_d, result.months.first.net_worth
    assert_equal 0.to_d, result.months.first.source_breakdown.fetch("debt_payment_cash_gap").to_d
    assert_equal 100.to_d, result.months.first.source_breakdown.fetch("debt_payment_effect_credit").to_d
  end

  test "loan payment transfer events consumed by debt adapter are not applied twice" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    liability_id = accounts(:loan).id
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 1000.to_d, risk_flags: [], source_snapshot: {} },
        { id: liability_id, classification: "liability", accountable_type: "Loan", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { account_id: liability_id, period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 0.to_d, risk_flags: [] }
      ],
      goals: [],
      events: [
        {
          id: SecureRandom.uuid,
          effect_type: "transfer",
          transaction_kind: "loan_payment",
          account_id: accounts(:depository).id,
          destination_account_id: liability_id,
          date: Date.current,
          budget_flow_type: "expense",
          category_id: nil,
          expected_income: 0.to_d,
          expected_spending: 100.to_d,
          cash_delta: -100.to_d,
          liquid_delta: -100.to_d,
          debt_delta: -100.to_d,
          portfolio_delta: 0.to_d,
          net_worth_delta: 0.to_d,
          risk_flags: []
        }
      ],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 900.to_d, result.months.first.cash_balance
    assert_equal 900.to_d, result.months.first.debt_balance
    assert_equal 0.to_d, result.months.first.source_breakdown.fetch("debt_projection_adjustment").to_d
  end

  test "recurring debt payments are not double-applied when debt adapter already included them" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    liability_id = accounts(:credit_card).id
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "daily_backed")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 1000.to_d, risk_flags: [], source_snapshot: {} },
        { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [
        {
          id: SecureRandom.uuid,
          destination_account_id: liability_id,
          date: Date.current,
          transaction_kind: "cc_payment",
          budget_flow_type: "none",
          expected_income: 0.to_d,
          expected_spending: 0.to_d,
          cash_delta: -100.to_d,
          liquid_delta: -100.to_d,
          debt_delta: -100.to_d,
          portfolio_delta: 0.to_d,
          net_worth_delta: 0.to_d,
          risk_flags: []
        }
      ],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { account_id: liability_id, period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 0.to_d, source: "account_balance_only", risk_flags: [ { "type" => "debt_projection_incomplete" } ] }
      ],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 900.to_d, result.months.first.cash_balance
    assert_equal 900.to_d, result.months.first.debt_balance
    assert_equal 0.to_d, result.months.first.source_breakdown.fetch("debt_payment_cash_gap").to_d
    assert_equal 0.to_d, result.months.first.source_breakdown.fetch("debt_projection_adjustment").to_d
  end

  test "pending liability payments adjust monthly debt even when debt projection rows exist" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.beginning_of_month
    period_end = Date.current.end_of_month
    liability_id = accounts(:credit_card).id
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: (Date.current..period_end).to_a,
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "daily_backed")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [],
      pending_entries: [
        {
          id: SecureRandom.uuid,
          account_id: liability_id,
          date: Date.current,
          transaction_kind: "standard",
          effect_label: "liability_payment_without_source",
          budget_flow_type: "none",
          pending_income: 0.to_d,
          pending_spending: 0.to_d,
          expected_income: 0.to_d,
          expected_spending: 0.to_d,
          cash_delta: 0.to_d,
          liquid_delta: 0.to_d,
          debt_delta: -200.to_d,
          portfolio_delta: 0.to_d,
          net_worth_delta: 200.to_d,
          risk_flags: []
        }
      ],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { period_start_on: period_start, ending_balance: 1000.to_d, cash_payment_gap: 0.to_d, risk_flags: [] }
      ],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call

    assert_equal 800.to_d, result.months.first.debt_balance
  end

  test "flags debt_pressures_runway when an unbudgeted debt cash gap drives cash below zero" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    liability_id = SecureRandom.uuid
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 50.to_d, risk_flags: [], source_snapshot: {} },
        { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { account_id: liability_id, period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 100.to_d, risk_flags: [] }
      ],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call
    month = result.months.first
    flag = month.risk_flags.find { |row| row["type"] == "debt_pressures_runway" }

    assert_equal(-50.to_d, month.cash_balance)
    assert flag.present?
    assert_equal [ liability_id ], flag.fetch("account_ids")
    assert_includes result.risk_flags, flag
  end

  test "does not flag debt_pressures_runway when cash stays above the floor" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    liability_id = SecureRandom.uuid
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 1000.to_d, risk_flags: [], source_snapshot: {} },
        { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { account_id: liability_id, period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 100.to_d, risk_flags: [] }
      ],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call
    month = result.months.first

    assert_equal 900.to_d, month.cash_balance
    assert_nil month.risk_flags.find { |row| row["type"] == "debt_pressures_runway" }
  end

  test "uses a minimum_cash_balance goal target as the debt-pressure floor" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    liability_id = SecureRandom.uuid
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 550.to_d, risk_flags: [], source_snapshot: {} },
        { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [
        { account_id: liability_id, period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 100.to_d, risk_flags: [] }
      ],
      goals: [
        {
          "id" => SecureRandom.uuid,
          "goal_type" => "minimum_cash_balance",
          "target_amount" => 500.to_d,
          "required" => true,
          "blocking_behavior" => "warns",
          "evaluation_starts_on" => period_start.iso8601,
          "evaluation_ends_on" => period_end.iso8601
        }
      ],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call
    month = result.months.first
    flag = month.risk_flags.find { |row| row["type"] == "debt_pressures_runway" }

    assert_equal 450.to_d, month.cash_balance
    assert flag.present?
    assert_equal "500.0", flag.fetch("cash_floor")
    assert_equal [ liability_id ], flag.fetch("account_ids")
  end

  test "records total_debt_delta and debt_to_cash_ratio for amortizing and growing debt months" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    liability_id = SecureRandom.uuid
    build_input = lambda do |ending_balance|
      Forecast::InputBuilder::Result.new(
        family: family,
        user: user,
        currency: family.currency,
        periods: Forecast::PeriodBuilder::Result.new(
          days: [],
          months: [
            Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
          ]
        ),
        scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
        accounts: [
          { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 2000.to_d, risk_flags: [], source_snapshot: {} },
          { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
        ],
        budgets: [],
        recurring_items: [],
        pending_entries: [],
        portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
        debt_rows: [
          { account_id: liability_id, period_start_on: period_start, ending_balance: ending_balance, cash_payment_gap: 0.to_d, risk_flags: [] }
        ],
        goals: [],
        events: [],
        source_data_versions: {},
        risk_flags: []
      )
    end

    amortizing = Forecast::Engine.new(build_input.call(900.to_d)).call.months.first
    growing = Forecast::Engine.new(build_input.call(1100.to_d)).call.months.first

    assert_equal(-100.to_d, amortizing.source_breakdown.fetch("total_debt_delta").to_d)
    assert_equal "0.45", amortizing.source_breakdown.fetch("debt_to_cash_ratio")
    assert_equal 100.to_d, growing.source_breakdown.fetch("total_debt_delta").to_d
    assert_equal "0.55", growing.source_breakdown.fetch("debt_to_cash_ratio")
  end

  test "emits no debt-pressure flag and zero debt delta when there are no debt rows" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    input = Forecast::InputBuilder::Result.new(
      family: family,
      user: user,
      currency: family.currency,
      periods: Forecast::PeriodBuilder::Result.new(
        days: [],
        months: [
          Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
        ]
      ),
      scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
      accounts: [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
      ],
      budgets: [],
      recurring_items: [],
      pending_entries: [],
      portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
      debt_rows: [],
      goals: [],
      events: [],
      source_data_versions: {},
      risk_flags: []
    )

    result = Forecast::Engine.new(input).call
    month = result.months.first

    assert_nil month.risk_flags.find { |row| row["type"] == "debt_pressures_runway" }
    assert_equal "0.0", month.source_breakdown.fetch("total_debt_delta")
    assert_equal "0.0", month.source_breakdown.fetch("debt_to_cash_ratio")
  end

  test "produces identical debt-pressure flags and breakdown for identical inputs" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period_start = Date.current.next_month.beginning_of_month
    period_end = period_start.end_of_month
    liability_id = SecureRandom.uuid
    cash_id = SecureRandom.uuid
    build_input = lambda do
      Forecast::InputBuilder::Result.new(
        family: family,
        user: user,
        currency: family.currency,
        periods: Forecast::PeriodBuilder::Result.new(
          days: [],
          months: [
            Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "monthly")
          ]
        ),
        scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
        accounts: [
          { id: cash_id, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: 50.to_d, risk_flags: [], source_snapshot: {} },
          { id: liability_id, classification: "liability", accountable_type: "CreditCard", liquidity_class: "debt", balance: 1000.to_d, risk_flags: [], source_snapshot: {} }
        ],
        budgets: [],
        recurring_items: [],
        pending_entries: [],
        portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
        debt_rows: [
          { account_id: liability_id, period_start_on: period_start, ending_balance: 900.to_d, cash_payment_gap: 100.to_d, risk_flags: [] }
        ],
        goals: [],
        events: [],
        source_data_versions: {},
        risk_flags: []
      )
    end

    first = Forecast::Engine.new(build_input.call).call.months.first
    second = Forecast::Engine.new(build_input.call).call.months.first

    assert_equal first.risk_flags, second.risk_flags
    assert_equal first.source_breakdown, second.source_breakdown
  end

  test "cash to restricted reclassification at month 5 drops cash and cash runway while net worth stays flat" do
    months = reclassification_months(6)
    move_month = months[4] # month 5 (1-based)
    input = monthly_reclassification_input(
      months: months,
      opening_cash: 6000.to_d,
      reclassifications: [
        reclassification_row(date: move_month.start_date, cash_delta: -6000.to_d, liquid_delta: -6000.to_d)
      ]
    )

    result = Forecast::Engine.new(input).call
    rows = result.months

    # Before the move: full cash and a 60-day runway (6000 / (3000/30)).
    assert_equal 6000.to_d, rows[3].cash_balance
    assert_equal 6000.to_d, rows[3].liquid_balance
    assert_equal 60, rows[3].cash_runway_days

    # From month 5 onward the same money is bucketed as restricted: cash and runway drop.
    assert_equal 0.to_d, rows[4].cash_balance
    assert_equal 0.to_d, rows[4].liquid_balance
    assert_equal 0, rows[4].cash_runway_days
    assert_equal 0.to_d, rows[5].cash_balance

    # Net worth is unchanged across the boundary: reclassification only re-buckets money.
    assert_equal rows[3].net_worth, rows[4].net_worth
    assert_equal 6000.to_d, rows[4].net_worth

    # Explainability: the move's cash net is surfaced on the effect month only.
    assert_equal "-6000.0", rows[4].source_breakdown.fetch("liquidity_reclassification_net")
    assert_equal "0.0", rows[3].source_breakdown.fetch("liquidity_reclassification_net")
    assert_equal "0.0", rows[5].source_breakdown.fetch("liquidity_reclassification_net")
  end

  test "minimum_cash_runway goal that passed before the move is blocked after the move" do
    months = reclassification_months(6)
    move_month = months[4]
    input = monthly_reclassification_input(
      months: months,
      opening_cash: 6000.to_d,
      reclassifications: [
        reclassification_row(date: move_month.start_date, cash_delta: -6000.to_d, liquid_delta: -6000.to_d)
      ],
      goals: [
        {
          "id" => SecureRandom.uuid,
          "goal_type" => "minimum_cash_runway",
          "target_duration_days" => 30.to_d,
          "required" => true,
          "blocking_behavior" => "blocks",
          "evaluation_starts_on" => months.first.start_date.iso8601,
          "evaluation_ends_on" => months.last.end_date.iso8601
        }
      ]
    )

    result = Forecast::Engine.new(input).call
    evaluation = result.goal_evaluations.first

    # Min runway over the window is 0 (post-move), below the 30-day target -> blocking.
    assert_equal "blocking", evaluation.status
    assert_equal 0.to_d, evaluation.metric_value
    assert_equal "blocked", result.feasibility_status

    # Sanity: without the move the same goal would pass at a 60-day runway.
    baseline = Forecast::Engine.new(
      monthly_reclassification_input(
        months: months,
        opening_cash: 6000.to_d,
        reclassifications: [],
        goals: input.goals
      )
    ).call
    assert_equal "pass", baseline.goal_evaluations.first.status
    assert_equal 60.to_d, baseline.goal_evaluations.first.metric_value
  end

  test "liquid to cash reclassification increases cash runway" do
    months = reclassification_months(6)
    move_month = months[4]
    # Money already in the liquid bucket (liquid includes cash) moves INTO cash, so only
    # the cash bucket gains balance; the liquid total is unchanged.
    input = monthly_reclassification_input(
      months: months,
      opening_cash: 3000.to_d,
      opening_liquid_extra: 3000.to_d,
      reclassifications: [
        reclassification_row(date: move_month.start_date, cash_delta: 3000.to_d, liquid_delta: 0.to_d)
      ]
    )

    result = Forecast::Engine.new(input).call
    rows = result.months

    assert_equal 3000.to_d, rows[3].cash_balance
    assert_equal 30, rows[3].cash_runway_days

    assert_equal 6000.to_d, rows[4].cash_balance
    assert_equal 60, rows[4].cash_runway_days

    # Liquid total never changed across the move.
    assert_equal rows[3].liquid_balance, rows[4].liquid_balance
  end

  test "reclassification delta is applied exactly once and not reflected in opening balances" do
    months = reclassification_months(6)
    move_month = months[4]
    input = monthly_reclassification_input(
      months: months,
      opening_cash: 6000.to_d,
      reclassifications: [
        reclassification_row(date: move_month.start_date, cash_delta: -6000.to_d, liquid_delta: -6000.to_d)
      ]
    )

    result = Forecast::Engine.new(input).call
    rows = result.months

    # Opening months keep their as-of-start classification: the future move is NOT
    # pulled back into the opening balance.
    assert_equal 6000.to_d, rows[0].cash_balance
    assert_equal 6000.to_d, rows[3].cash_balance

    # The -6000 delta is reflected once (a single 6000 -> 0 step), never twice.
    assert_equal 0.to_d, rows[4].cash_balance
    assert_equal 0.to_d, rows[5].cash_balance

    # Exactly one month carries the net; all others are zero.
    nets = rows.map { |row| row.source_breakdown.fetch("liquidity_reclassification_net").to_d }
    assert_equal [ -6000.to_d ], nets.reject(&:zero?)
  end

  test "no reclassifications leaves month rows identical to the pre-wiring baseline" do
    months = reclassification_months(6)
    with_reclass = monthly_reclassification_input(months: months, opening_cash: 6000.to_d, reclassifications: [])
    without_field = monthly_reclassification_input(months: months, opening_cash: 6000.to_d, reclassifications: nil)

    with_result = Forecast::Engine.new(with_reclass).call
    without_result = Forecast::Engine.new(without_field).call

    with_result.months.zip(without_result.months).each do |a, b|
      assert_equal b.cash_balance, a.cash_balance
      assert_equal b.liquid_balance, a.liquid_balance
      assert_equal b.net_worth, a.net_worth
      assert_equal b.cash_runway_days, a.cash_runway_days
      assert_equal b.source_breakdown.except("liquidity_reclassification_net"), a.source_breakdown.except("liquidity_reclassification_net")
    end
    # The new key defaults to zero with no moves.
    assert with_result.months.all? { |row| row.source_breakdown.fetch("liquidity_reclassification_net") == "0.0" }
  end

  test "reclassification projection is deterministic across repeated runs" do
    months = reclassification_months(6)
    move_month = months[4]
    build = lambda do
      monthly_reclassification_input(
        months: months,
        opening_cash: 6000.to_d,
        reclassifications: [
          reclassification_row(date: move_month.start_date, cash_delta: -6000.to_d, liquid_delta: -6000.to_d)
        ]
      )
    end

    first = Forecast::Engine.new(build.call).call.months
    second = Forecast::Engine.new(build.call).call.months

    assert_equal first.map(&:cash_balance), second.map(&:cash_balance)
    assert_equal first.map(&:liquid_balance), second.map(&:liquid_balance)
    assert_equal first.map(&:source_breakdown), second.map(&:source_breakdown)
  end

  private
    # Builds N consecutive monthly-precision period windows starting next month so the
    # whole horizon sits in the future (no day rows, no partial-current-period branch).
    def reclassification_months(count)
      base = Date.current.next_month.beginning_of_month
      count.times.map do |index|
        start_date = base + index.months
        Forecast::PeriodBuilder::PeriodWindow.new(
          index: index,
          start_date: start_date,
          end_date: start_date.end_of_month,
          precision: "monthly"
        )
      end
    end

    def reclassification_row(date:, cash_delta:, liquid_delta:)
      {
        date: date,
        name: "Liquidity reclassification",
        effect_type: "liquidity_reclassification",
        account_id: SecureRandom.uuid,
        expected_income: 0.to_d,
        expected_spending: 0.to_d,
        cash_delta: cash_delta,
        liquid_delta: liquid_delta,
        debt_delta: 0.to_d,
        portfolio_delta: 0.to_d,
        net_worth_delta: 0.to_d,
        budget_flow_type: "none",
        transaction_kind: "liquidity_reclassification",
        source_snapshot: { "type" => "liquidity_reclassification" },
        risk_flags: []
      }
    end

    # A monthly forecast with a single cash account and a flat 3000/month uncategorized
    # budget (actual == budgeted so no spend gap touches cash; runway burn is 3000/mo).
    # opening_liquid_extra adds a separate liquid-but-not-cash account so liquid > cash.
    # reclassifications: pass [] for the empty stream or nil to omit the field entirely.
    def monthly_reclassification_input(months:, opening_cash:, reclassifications:, goals: [], opening_liquid_extra: 0.to_d)
      family = families(:dylan_family)
      user = users(:family_admin)
      accounts = [
        { id: SecureRandom.uuid, classification: "asset", accountable_type: "Depository", liquidity_class: "cash", balance: opening_cash, risk_flags: [], source_snapshot: {} }
      ]
      if opening_liquid_extra.positive?
        accounts << { id: SecureRandom.uuid, classification: "asset", accountable_type: "Investment", liquidity_class: "liquid", balance: opening_liquid_extra, risk_flags: [], source_snapshot: {} }
      end
      budgets = months.map do |period|
        {
          period_start_on: period.start_date,
          expected_income: 0.to_d,
          actual_income: 0.to_d,
          budgeted_uncategorized_spending: 3000.to_d,
          actual_uncategorized_spending: 3000.to_d,
          source_budget_id: nil,
          categories: []
        }
      end
      attributes = {
        family: family,
        user: user,
        currency: family.currency,
        periods: Forecast::PeriodBuilder::Result.new(days: [], months: months),
        scenario_stack: Forecast::ScenarioStack::Result.new(key: "baseline", scenario_ids: [], snapshot: {}, risk_flags: []),
        accounts: accounts,
        budgets: budgets,
        recurring_items: [],
        pending_entries: [],
        portfolio: { portfolio_value: 0.to_d, holdings: [], risk_flags: [] },
        debt_rows: [],
        goals: goals,
        events: [],
        source_data_versions: {},
        risk_flags: []
      }
      attributes[:reclassifications] = reclassifications unless reclassifications.nil?
      Forecast::InputBuilder::Result.new(**attributes)
    end
end
