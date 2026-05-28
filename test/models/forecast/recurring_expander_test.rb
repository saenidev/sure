require "test_helper"

class Forecast::RecurringExpanderTest < ActiveSupport::TestCase
  test "returns no rows when recurring transactions are disabled" do
    family = families(:dylan_family)
    family.update!(recurring_transactions_disabled: true)

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call

    assert_empty result
  end

  test "internal funds movement is not income or spending" do
    family = families(:dylan_family)
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: family, scenario_ids: [])
    )

    effect = classifier.call(
      source_account: accounts(:depository),
      destination_account: accounts(:connected),
      amount: 500
    )

    assert_equal "funds_movement", effect.fetch(:transaction_kind)
    assert_equal "none", effect.fetch(:budget_flow_type)
    assert_equal 0.to_d, effect.fetch(:expected_income)
    assert_equal 0.to_d, effect.fetch(:expected_spending)
  end

  test "portfolio withdrawal transfer reduces portfolio without income" do
    family = families(:dylan_family)
    classifier = Forecast::TransferClassifier.new(
      liquidity_classifier: Forecast::LiquidityClassifier.new(family: family, scenario_ids: [])
    )

    effect = classifier.call(
      source_account: accounts(:investment),
      destination_account: accounts(:depository),
      amount: 500
    )

    assert_equal "funds_movement", effect.fetch(:transaction_kind)
    assert_equal "none", effect.fetch(:budget_flow_type)
    assert_equal 500.to_d, effect.fetch(:cash_delta)
    assert_equal(-500.to_d, effect.fetch(:portfolio_delta))
    assert_equal 0.to_d, effect.fetch(:net_worth_delta)
  end

  test "same-scope cross-currency recurring transfer is unmodeled instead of source-only" do
    family = families(:dylan_family)
    accounts(:investment).update!(currency: "EUR")
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id, accounts(:investment).id ], [ accounts(:depository).id, accounts(:investment).id ])
    recurring = family.recurring_transactions.create!(
      account: accounts(:depository),
      destination_account: accounts(:investment),
      name: "Monthly foreign brokerage transfer",
      amount: 100,
      currency: family.currency,
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active",
      occurrence_count: 1,
      manual: true
    )

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: included_scope
    ).call
    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }

    assert_equal 0.to_d, row.fetch(:cash_delta)
    assert_equal 0.to_d, row.fetch(:portfolio_delta)
    assert_equal 0.to_d, row.fetch(:net_worth_delta)
    assert row.fetch(:risk_flags).any? { |flag| flag["type"] == "cross_currency_recurring_transfer_destination_amount_unmodeled" }
  end

  test "unmodeled cross-currency recurring transfer does not require source FX" do
    family = families(:dylan_family)
    accounts(:depository).update!(currency: "EUR")
    accounts(:investment).update!(currency: "KRW")
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id, accounts(:investment).id ], [ accounts(:depository).id, accounts(:investment).id ])
    recurring = family.recurring_transactions.create!(
      account: accounts(:depository),
      destination_account: accounts(:investment),
      name: "Monthly foreign brokerage transfer",
      amount: 100,
      currency: "EUR",
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active",
      occurrence_count: 1,
      manual: true
    )
    ExchangeRate.expects(:find_or_fetch_rate).never

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: included_scope
    ).call

    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }
    assert_equal 0.to_d, row.fetch(:amount)
    assert row.fetch(:risk_flags).any? { |flag| flag["type"] == "cross_currency_recurring_transfer_destination_amount_unmodeled" }
  end

  test "source-only cross-currency recurring transfer applies included outflow" do
    family = families(:dylan_family)
    accounts(:investment).update!(currency: "EUR")
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id ], [ accounts(:depository).id ])
    recurring = family.recurring_transactions.create!(
      account: accounts(:depository),
      destination_account: accounts(:investment),
      name: "Monthly foreign brokerage transfer",
      amount: 100,
      currency: family.currency,
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active",
      occurrence_count: 1,
      manual: true
    )

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: included_scope
    ).call
    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }

    assert_equal(-100.to_d, row.fetch(:cash_delta))
    assert_equal(-100.to_d, row.fetch(:liquid_delta))
    assert_equal(-100.to_d, row.fetch(:net_worth_delta))
    assert row.fetch(:risk_flags).any? { |flag| flag["type"] == "cross_currency_recurring_transfer_destination_amount_unmodeled" }
  end

  test "recurring investment contribution uses canonical investment contribution category" do
    family = families(:dylan_family)
    category = I18n.with_locale(family.locale) do
      family.categories.find_or_create_by!(name: Category.investment_contributions_name) do |new_category|
        new_category.color = "#0d9488"
        new_category.lucide_icon = "trending-up"
      end
    end
    recurring = family.recurring_transactions.create!(
      name: "Brokerage contribution",
      amount: 400,
      currency: family.currency,
      account: accounts(:depository),
      destination_account: accounts(:investment),
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active"
    )

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }

    assert_equal "investment_contribution", row.fetch(:transaction_kind)
    assert_equal category.id, row.fetch(:category_id)
  end

  test "recurring loan payment finds existing loan category across locale changes" do
    family = families(:dylan_family)
    english_loan_category = family.categories.find_or_create_by!(name: I18n.t("models.category.defaults.loan_payments", locale: :en)) do |category|
      category.color = "#e11d48"
      category.lucide_icon = "credit-card"
    end
    family.update!(locale: "ca")
    recurring = family.recurring_transactions.create!(
      name: "Loan payment",
      amount: 400,
      currency: family.currency,
      account: accounts(:depository),
      destination_account: accounts(:loan),
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active"
    )

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }

    assert_equal "loan_payment", row.fetch(:transaction_kind)
    assert_equal english_loan_category.id, row.fetch(:category_id)
  end

  test "recurring category inference ignores history from accounts excluded from forecast scope" do
    family = families(:dylan_family)
    historical_transaction = Transaction.create!(category: categories(:food_and_drink))
    Entry.create!(
      account: accounts(:connected),
      entryable: historical_transaction,
      name: "Scoped merchant",
      date: 1.week.ago.to_date,
      amount: 40,
      currency: family.currency
    )
    recurring = family.recurring_transactions.create!(
      name: "Scoped merchant",
      amount: 40,
      currency: family.currency,
      account: accounts(:depository),
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active"
    )
    included_scope = Struct.new(:id_values).new([ accounts(:depository).id ])

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: included_scope
    ).call
    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }

    assert_nil row.fetch(:category_id)
  end

  test "recurring transfer from included source to excluded destination affects scoped balances" do
    family = families(:dylan_family)
    recurring = family.recurring_transactions.create!(
      name: "Outside brokerage contribution",
      amount: 400,
      currency: family.currency,
      account: accounts(:depository),
      destination_account: accounts(:investment),
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active"
    )
    included_scope = Struct.new(:id_values).new([ accounts(:depository).id ])

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: included_scope
    ).call
    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }

    assert_equal "investment_contribution", row.fetch(:transaction_kind)
    assert_equal "expense", row.fetch(:budget_flow_type)
    assert_equal 400.to_d, row.fetch(:expected_spending)
    assert_equal(-400.to_d, row.fetch(:cash_delta))
    assert_equal(-400.to_d, row.fetch(:net_worth_delta))
  end

  test "recurring income remains income after expansion" do
    family = families(:dylan_family)
    recurring = family.recurring_transactions.create!(
      name: "Paycheck",
      amount: -3000,
      currency: family.currency,
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active"
    )

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 1.month.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call

    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }

    assert_equal "income", row.fetch(:budget_flow_type)
    assert_equal 3000.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:expected_spending)
  end

  test "non-transfer recurring rows from tax advantaged accounts are budget neutral" do
    family = families(:dylan_family)
    accounts(:investment).accountable.update!(subtype: "401k")
    recurring = family.recurring_transactions.create!(
      name: "Retirement dividend",
      amount: -100,
      currency: family.currency,
      account: accounts(:investment),
      expected_day_of_month: Date.current.day,
      next_expected_date: Date.current,
      last_occurrence_date: 1.month.ago.to_date,
      status: "active"
    )

    result = Forecast::RecurringExpander.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:recurring_transaction_id) == recurring.id }

    assert_equal "none", row.fetch(:budget_flow_type)
    assert_equal 0.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:expected_spending)
  end
end
