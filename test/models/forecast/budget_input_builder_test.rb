require "test_helper"
require "ostruct"

class Forecast::BudgetInputBuilderTest < ActiveSupport::TestCase
  test "uses parent budget rows only and does not create future budgets" do
    family = families(:dylan_family)
    user = users(:family_admin)
    budget = budgets(:one)
    budget.budget_categories.find_or_create_by!(category: categories(:food_and_drink)) { |bc| bc.budgeted_spending = 500; bc.currency = family.currency }
    budget.budget_categories.find_or_create_by!(category: categories(:subcategory)) { |bc| bc.budgeted_spending = 200; bc.currency = family.currency }
    before_count = Budget.count

    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: budget.start_date, end_date: budget.end_date, precision: "daily_backed")
    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    category_ids = result.first.fetch(:categories).map { |row| row.fetch(:category_id) }
    assert_includes category_ids, categories(:food_and_drink).id
    assert_not_includes category_ids, categories(:subcategory).id
    assert_equal before_count, Budget.count
  end

  test "future budget inheritance ignores uninitialized budget shells" do
    family = families(:dylan_family)
    user = users(:family_admin)
    initialized_budget = budgets(:one)
    initialized_budget.budget_categories.find_or_create_by!(category: categories(:food_and_drink)) { |bc| bc.budgeted_spending = 500; bc.currency = family.currency }
    shell_start = initialized_budget.start_date.next_month.beginning_of_month
    uninitialized_shell = family.budgets.create!(
      start_date: shell_start,
      end_date: shell_start.end_of_month,
      currency: family.currency
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: shell_start, end_date: shell_start.end_of_month, precision: "monthly")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    assert_equal initialized_budget.id, result.first.fetch(:source_budget_id)
    assert_not_equal uninitialized_shell.id, result.first.fetch(:source_budget_id)
  end

  test "forecast budget override can adjust a monthly category without creating real budgets" do
    family = families(:dylan_family)
    user = users(:family_admin)
    budget = budgets(:one)
    category = categories(:food_and_drink)
    budget.budget_categories.find_or_create_by!(category: category) { |bc| bc.budgeted_spending = 500; bc.currency = family.currency }
    family.forecast_budget_overrides.create!(
      period_start_on: budget.start_date,
      override_type: "category_spending",
      category: category,
      amount: 900,
      currency: family.currency
    )
    before_count = Budget.count
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: budget.start_date, end_date: budget.end_date, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = result.first.fetch(:categories).find { |candidate| candidate.fetch(:category_id) == category.id }
    assert_equal "forecast_budget_override", row.fetch(:source)
    assert_equal 900.to_d, row.fetch(:budgeted_spending)
    assert_equal before_count, Budget.count
  end

  test "scenario override-only categories collapse to the active stack override" do
    family = families(:dylan_family)
    user = users(:family_admin)
    family.budgets.destroy_all
    category = categories(:food_and_drink)
    period_start = family.custom_month_start_for(Date.current)
    period_end = family.custom_month_end_for(Date.current)
    scenario = family.forecast_scenarios.create!(name: "Higher food costs", status: "active", starts_on: period_start, ends_on: period_end)
    family.forecast_budget_overrides.create!(
      period_start_on: period_start,
      override_type: "category_spending",
      category: category,
      amount: 500,
      currency: family.currency
    )
    family.forecast_budget_overrides.create!(
      forecast_scenario: scenario,
      period_start_on: period_start,
      override_type: "category_spending",
      category: category,
      amount: 900,
      currency: family.currency
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_end, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [ scenario.id ],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    rows = result.first.fetch(:categories).select { |candidate| candidate.fetch(:category_id) == category.id }
    assert_equal 1, rows.size
    assert_equal 900.to_d, rows.first.fetch(:budgeted_spending)
  end

  test "scenario budget overrides do not apply outside the scenario date window" do
    family = families(:dylan_family)
    user = users(:family_admin)
    family.budgets.destroy_all
    category = categories(:food_and_drink)
    entries(:transaction).destroy!
    current_start = family.custom_month_start_for(Date.current)
    current_end = family.custom_month_end_for(Date.current)
    next_start = current_start.next_month
    next_end = family.custom_month_end_for(next_start)
    scenario = family.forecast_scenarios.create!(name: "Later move", status: "active", starts_on: next_start, ends_on: next_end)
    family.forecast_budget_overrides.create!(
      forecast_scenario: scenario,
      period_start_on: next_start,
      override_type: "category_spending",
      category: category,
      amount: 900,
      currency: family.currency
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: current_start, end_date: current_end, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [ scenario.id ],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    assert_empty result.first.fetch(:categories).select { |candidate| candidate.fetch(:category_id) == category.id }
  end

  test "posted liability payments are not treated as budget income" do
    family = families(:dylan_family)
    user = users(:family_admin)
    budget = budgets(:one)
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: -250, account: accounts(:credit_card))
    entry.transaction.update!(kind: "standard", category: categories(:income))
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: budget.start_date, end_date: budget.end_date, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    assert_equal 0.to_d, result.first.fetch(:actual_income)
    assert result.first.fetch(:risk_flags).any? { |flag| flag["type"] == "actual_liability_payment_excluded_from_income" }
  end

  test "actual income is entry-derived even when no budget exists" do
    family = families(:dylan_family)
    user = users(:family_admin)
    family.budgets.destroy_all
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: -750, account: accounts(:depository))
    entry.transaction.update!(kind: "standard", category: categories(:income))
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    assert_equal 750.to_d, result.first.fetch(:actual_income)
    assert_empty result.first.fetch(:categories).select { |row| row.fetch(:category_id) == categories(:income).id && row.fetch(:actual_spending).positive? }
  end

  test "actual category rows are entry-derived without a budget and exclude tax advantaged accounts" do
    family = families(:dylan_family)
    user = users(:family_admin)
    family.budgets.destroy_all
    accounts(:investment).accountable.update!(subtype: "401k")
    taxable_entry = entries(:transaction)
    taxable_entry.update!(date: Date.current, amount: 50, account: accounts(:depository))
    taxable_entry.transaction.update!(kind: "standard", category: categories(:food_and_drink))
    tax_advantaged_transaction = Transaction.create!(kind: "standard", category: categories(:food_and_drink))
    Entry.create!(
      account: accounts(:investment),
      entryable: tax_advantaged_transaction,
      name: "Retirement cafeteria",
      date: Date.current,
      amount: 500,
      currency: family.currency
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    category = result.first.fetch(:categories).find { |row| row.fetch(:category_id) == categories(:food_and_drink).id }
    assert_equal "actual", category.fetch(:source)
    assert_equal 50.to_d, category.fetch(:actual_spending)
  end

  test "actual FX conversion uses each entry date instead of the run date" do
    family = families(:dylan_family)
    user = users(:family_admin)
    entry_date = 5.days.ago.to_date
    entry = entries(:transaction)
    entry.update!(date: entry_date, amount: 10, currency: "EUR", account: accounts(:depository))
    entry.transaction.update!(kind: "standard", category: categories(:food_and_drink))
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: entry_date.beginning_of_month, end_date: entry_date.end_of_month, precision: "daily_backed")
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: entry_date, cache: false)
      .returns(OpenStruct.new(rate: 2.to_d, date: entry_date))

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    category = result.first.fetch(:categories).find { |row| row.fetch(:category_id) == categories(:food_and_drink).id }
    assert_equal 20.to_d, category.fetch(:actual_spending)
  end

  test "actual-only category rows net refunds and ignore internal investment movements" do
    family = families(:dylan_family)
    user = users(:family_admin)
    family.budgets.destroy_all
    purchase = entries(:transaction)
    purchase.update!(date: Date.current, amount: 100, account: accounts(:depository))
    purchase.transaction.update!(kind: "standard", category: categories(:food_and_drink))
    refund = Transaction.create!(kind: "standard", category: categories(:food_and_drink))
    Entry.create!(account: accounts(:depository), entryable: refund, name: "Refund", date: Date.current, amount: -30, currency: family.currency)
    sweep = Transaction.create!(kind: "standard", category: categories(:food_and_drink), investment_activity_label: "Sweep In")
    Entry.create!(account: accounts(:depository), entryable: sweep, name: "Internal sweep", date: Date.current, amount: 1000, currency: family.currency)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    category = result.first.fetch(:categories).find { |row| row.fetch(:category_id) == categories(:food_and_drink).id }
    assert_equal 70.to_d, category.fetch(:actual_spending)
    assert_equal 0.to_d, result.first.fetch(:actual_income)
  end

  test "uncategorized actual spending is tracked separately for current-period budget gaps" do
    family = families(:dylan_family)
    user = users(:family_admin)
    family.budgets.destroy_all
    purchase = Transaction.create!(kind: "standard", category: nil)
    refund = Transaction.create!(kind: "standard", category: nil)
    Entry.create!(account: accounts(:depository), entryable: purchase, name: "Uncategorized purchase", date: Date.current, amount: 100, currency: family.currency)
    Entry.create!(account: accounts(:depository), entryable: refund, name: "Uncategorized refund", date: Date.current, amount: -25, currency: family.currency)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    assert_equal 75.to_d, result.first.fetch(:actual_uncategorized_spending)
    assert_equal 2, result.first.fetch(:uncategorized_actual_source_snapshot).size
  end

  test "posted investment to investment rollover actuals are budget neutral" do
    family = families(:dylan_family)
    user = users(:family_admin)
    family.budgets.destroy_all
    other_investment = family.accounts.create!(
      name: "IRA rollover target",
      balance: 5000,
      currency: family.currency,
      accountable: Investment.new(subtype: "brokerage")
    )
    category = family.categories.find_or_create_by!(name: Category.investment_contributions_name) do |new_category|
      new_category.color = "#0d9488"
      new_category.lucide_icon = "trending-up"
    end
    outflow = Transaction.create!(kind: "investment_contribution", category: category)
    inflow = Transaction.create!(kind: "funds_movement")
    Entry.create!(account: accounts(:investment), entryable: outflow, name: "Auto rollover out", date: Date.current, amount: 1000, currency: family.currency)
    Entry.create!(account: other_investment, entryable: inflow, name: "Auto rollover in", date: Date.current, amount: -1000, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    assert_nil result.first.fetch(:categories).find { |row| row.fetch(:category_id) == category.id }
  end

  test "posted transfer actuals from included source to excluded destination count by Sure entry scope" do
    family = families(:dylan_family)
    user = users(:family_admin)
    family.budgets.destroy_all
    loan_category = family.categories.find_or_create_by!(name: "Mortgage") do |category|
      category.color = "#0d9488"
      category.lucide_icon = "house"
    end
    outflow = Transaction.create!(kind: "loan_payment", category: loan_category)
    inflow = Transaction.create!(kind: "funds_movement")
    Entry.create!(account: accounts(:depository), entryable: outflow, name: "Scoped loan payment", date: Date.current, amount: 100, currency: family.currency)
    Entry.create!(account: accounts(:loan), entryable: inflow, name: "Scoped loan payment received", date: Date.current, amount: -100, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id ], [ accounts(:depository).id ])
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, precision: "daily_backed")

    result = Forecast::BudgetInputBuilder.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: included_scope
    ).call

    category = result.first.fetch(:categories).find { |row| row.fetch(:category_id) == loan_category.id }
    assert_equal "actual", category.fetch(:source)
    assert_equal 100.to_d, category.fetch(:actual_spending)
  end
end
