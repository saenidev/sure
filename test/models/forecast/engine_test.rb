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
end
