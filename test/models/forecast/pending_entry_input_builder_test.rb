require "test_helper"
require "ostruct"

class Forecast::PendingEntryInputBuilderTest < ActiveSupport::TestCase
  test "returns pending rows separately from posted actuals" do
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: 25, account: accounts(:depository))
    entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })

    result = Forecast::PendingEntryInputBuilder.new(
      family: families(:dylan_family),
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 90.days.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: families(:dylan_family), as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: families(:dylan_family), user: users(:family_admin))
    ).call

    assert_equal 1, result.size
    assert_equal "spending", result.first.fetch(:direction)
    assert_equal "expense", result.first.fetch(:budget_flow_type)
    assert_equal 25.to_d, result.first.fetch(:expected_spending)
    assert_equal 25.to_d, result.first.fetch(:pending_spending)
    assert_equal "pending", result.first.fetch(:status)
  end

  test "pending FX conversion uses each entry date instead of the run date" do
    family = families(:dylan_family)
    entry_date = 2.days.ago.to_date
    entry = entries(:transaction)
    entry.update!(date: entry_date, amount: 25, currency: "EUR", account: accounts(:depository))
    entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: entry_date, cache: false)
      .once
      .returns(OpenStruct.new(rate: 2.to_d, date: entry_date))

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: entry_date,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call

    assert_equal 50.to_d, result.first.fetch(:pending_spending)
    assert_equal entry_date.iso8601, result.first.fetch(:source_snapshot).fetch("money").fetch("exchange_rate_date")
  end

  test "pending budget-excluded transfer rows do not become income or spending" do
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: 250, account: accounts(:depository))
    entry.transaction.update!(kind: "funds_movement", extra: { "simplefin" => { "pending" => true } })

    result = Forecast::PendingEntryInputBuilder.new(
      family: families(:dylan_family),
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 90.days.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: families(:dylan_family), as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: families(:dylan_family), user: users(:family_admin))
    ).call

    row = result.first
    assert_equal "none", row.fetch(:budget_flow_type)
    assert_equal 0.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:expected_spending)
    assert_equal 0.to_d, row.fetch(:pending_income)
    assert_equal 0.to_d, row.fetch(:pending_spending)
  end

  test "pending investment contribution uses canonical investment contribution category" do
    family = families(:dylan_family)
    category = I18n.with_locale(family.locale) do
      family.categories.find_or_create_by!(name: Category.investment_contributions_name) do |new_category|
        new_category.color = "#0d9488"
        new_category.lucide_icon = "trending-up"
      end
    end
    outflow = Transaction.create!(kind: "investment_contribution", category: category, extra: { "simplefin" => { "pending" => true } })
    inflow = Transaction.create!(kind: "investment_contribution", extra: { "simplefin" => { "pending" => true } })
    Entry.create!(
      account: accounts(:depository),
      entryable: outflow,
      name: "Pending brokerage contribution",
      date: Date.current,
      amount: 400,
      currency: family.currency
    )
    Entry.create!(
      account: accounts(:investment),
      entryable: inflow,
      name: "Pending brokerage contribution received",
      date: Date.current,
      amount: -400,
      currency: family.currency
    )
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:name) == "Pending brokerage contribution" }

    assert_equal "investment_contribution", row.fetch(:transaction_kind)
    assert_equal category.id, row.fetch(:category_id)
    assert_equal 400.to_d, row.fetch(:expected_spending)
  end

  test "provider imported pending investment contribution inflow is still an expense" do
    family = families(:dylan_family)
    category = I18n.with_locale(family.locale) do
      family.categories.find_or_create_by!(name: Category.investment_contributions_name) do |new_category|
        new_category.color = "#0d9488"
        new_category.lucide_icon = "trending-up"
      end
    end
    transaction = Transaction.create!(kind: "investment_contribution", category: category, extra: { "simplefin" => { "pending" => true } })
    entry = Entry.create!(
      account: accounts(:investment),
      entryable: transaction,
      name: "Pending provider contribution",
      date: Date.current,
      amount: -500,
      currency: family.currency
    )

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:id) == entry.id }

    assert_equal "investment_contribution", row.fetch(:transaction_kind)
    assert_equal "expense", row.fetch(:budget_flow_type)
    assert_equal 0.to_d, row.fetch(:expected_income)
    assert_equal 500.to_d, row.fetch(:expected_spending)
    assert_equal 500.to_d, row.fetch(:pending_spending)
    assert_equal 500.to_d, row.fetch(:portfolio_delta)
    assert_equal 500.to_d, row.fetch(:net_worth_delta)
  end

  test "pending credit card transfer uses transfer endpoint helpers and stays budget neutral" do
    family = families(:dylan_family)
    outflow = Transaction.create!(kind: "cc_payment", extra: { "simplefin" => { "pending" => true } })
    inflow = Transaction.create!(kind: "cc_payment", extra: { "simplefin" => { "pending" => true } })
    Entry.create!(account: accounts(:depository), entryable: outflow, name: "Pending card payment", date: Date.current, amount: 100, currency: family.currency)
    Entry.create!(account: accounts(:credit_card), entryable: inflow, name: "Pending card payment received", date: Date.current, amount: -100, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:name) == "Pending card payment" }

    assert_equal "cc_payment", row.fetch(:transaction_kind)
    assert_equal accounts(:credit_card).id, row.fetch(:destination_account_id)
    assert_equal 0.to_d, row.fetch(:expected_spending)
    assert_equal(-100.to_d, row.fetch(:debt_delta))
  end

  test "pending loan transfer uses transfer endpoint helpers and counts as spending" do
    family = families(:dylan_family)
    outflow = Transaction.create!(kind: "loan_payment", extra: { "simplefin" => { "pending" => true } })
    inflow = Transaction.create!(kind: "loan_payment", extra: { "simplefin" => { "pending" => true } })
    Entry.create!(account: accounts(:depository), entryable: outflow, name: "Pending loan payment", date: Date.current, amount: 100, currency: family.currency)
    Entry.create!(account: accounts(:loan), entryable: inflow, name: "Pending loan payment received", date: Date.current, amount: -100, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:name) == "Pending loan payment" }

    assert_equal "loan_payment", row.fetch(:transaction_kind)
    assert_equal accounts(:loan).id, row.fetch(:destination_account_id)
    assert_equal 100.to_d, row.fetch(:expected_spending)
    assert_equal(-100.to_d, row.fetch(:debt_delta))
  end

  test "pending transfer from included source to excluded destination affects scoped balances" do
    family = families(:dylan_family)
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id ], [ accounts(:depository).id ])
    outflow = Transaction.create!(kind: "investment_contribution", extra: { "simplefin" => { "pending" => true } })
    inflow = Transaction.create!(kind: "investment_contribution", extra: { "simplefin" => { "pending" => true } })
    Entry.create!(account: accounts(:depository), entryable: outflow, name: "Pending excluded transfer", date: Date.current, amount: 400, currency: family.currency)
    Entry.create!(account: accounts(:investment), entryable: inflow, name: "Pending excluded transfer received", date: Date.current, amount: -400, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: included_scope
    ).call

    row = result.find { |candidate| candidate.fetch(:name) == "Pending excluded transfer" }

    assert_equal "investment_contribution", row.fetch(:transaction_kind)
    assert_equal "expense", row.fetch(:budget_flow_type)
    assert_equal 400.to_d, row.fetch(:expected_spending)
    assert_equal(-400.to_d, row.fetch(:cash_delta))
    assert_equal(-400.to_d, row.fetch(:liquid_delta))
    assert_equal 0.to_d, row.fetch(:portfolio_delta)
    assert_equal(-400.to_d, row.fetch(:net_worth_delta))
  end

  test "pending one-sided transfer does not convert excluded foreign destination" do
    family = families(:dylan_family)
    accounts(:investment).update!(currency: "EUR")
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id ], [ accounts(:depository).id ])
    outflow = Transaction.create!(kind: "investment_contribution", extra: { "simplefin" => { "pending" => true } })
    inflow = Transaction.create!(kind: "investment_contribution", extra: { "simplefin" => { "pending" => true } })
    Entry.create!(account: accounts(:depository), entryable: outflow, name: "Pending foreign excluded transfer", date: Date.current, amount: 400, currency: family.currency)
    Entry.create!(account: accounts(:investment), entryable: inflow, name: "Pending foreign excluded transfer received", date: Date.current, amount: -350, currency: "EUR")
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "EUR", to: family.currency, date: Date.current, cache: false).never

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: included_scope
    ).call

    row = result.find { |candidate| candidate.fetch(:name) == "Pending foreign excluded transfer" }

    assert_equal(-400.to_d, row.fetch(:cash_delta))
    assert_equal(-400.to_d, row.fetch(:net_worth_delta))
    assert_equal({}, row.fetch(:source_snapshot).fetch("destination_money"))
  end

  test "pending transfer from excluded source to included destination affects scoped balances" do
    family = families(:dylan_family)
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id ], [ accounts(:depository).id ])
    outflow = Transaction.create!(kind: "funds_movement", extra: { "simplefin" => { "pending" => true } })
    inflow = Transaction.create!(kind: "funds_movement", extra: { "simplefin" => { "pending" => true } })
    Entry.create!(account: accounts(:investment), entryable: outflow, name: "Pending excluded source", date: Date.current, amount: 400, currency: family.currency)
    Entry.create!(account: accounts(:depository), entryable: inflow, name: "Pending included destination", date: Date.current, amount: -400, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: included_scope
    ).call

    row = result.find { |candidate| candidate.fetch(:name) == "Pending included destination" }

    assert_equal "funds_movement", row.fetch(:transaction_kind)
    assert_equal "none", row.fetch(:budget_flow_type)
    assert_equal 0.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:expected_spending)
    assert_equal 400.to_d, row.fetch(:cash_delta)
    assert_equal 400.to_d, row.fetch(:liquid_delta)
    assert_equal 400.to_d, row.fetch(:net_worth_delta)
  end

  test "pending liability payment is not classified as income" do
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: -75, account: accounts(:credit_card))
    entry.transaction.update!(kind: "standard", extra: { "simplefin" => { "pending" => true } })

    result = Forecast::PendingEntryInputBuilder.new(
      family: families(:dylan_family),
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 90.days.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: families(:dylan_family), as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: families(:dylan_family), user: users(:family_admin))
    ).call

    row = result.first
    assert_equal "debt_payment", row.fetch(:direction)
    assert_equal 0.to_d, row.fetch(:pending_income)
    assert_equal(-75.to_d, row.fetch(:debt_delta))
    assert row.fetch(:risk_flags).any? { |flag| flag["type"] == "liability_payment_source_missing" }
  end

  test "non-transfer pending income in a liquid investment account does not inflate cash" do
    family = families(:dylan_family)
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: -100, account: accounts(:investment))
    entry.transaction.update!(kind: "standard", category: categories(:income), extra: { "simplefin" => { "pending" => true } })

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:id) == entry.id }

    assert_equal "income", row.fetch(:budget_flow_type)
    assert_equal 0.to_d, row.fetch(:cash_delta)
    assert_equal 100.to_d, row.fetch(:liquid_delta)
    assert_equal 100.to_d, row.fetch(:portfolio_delta)
  end

  test "pending entries use scenario liquidity settings" do
    family = families(:dylan_family)
    scenario = family.forecast_scenarios.create!(name: "Bridge cash in brokerage", starts_on: Date.current, ends_on: Date.current)
    family.forecast_account_liquidity_settings.create!(
      forecast_scenario: scenario,
      account: accounts(:investment),
      liquidity_class: "cash",
      starts_on: Date.current,
      ends_on: Date.current
    )
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: -100, account: accounts(:investment))
    entry.transaction.update!(kind: "standard", category: categories(:income), extra: { "simplefin" => { "pending" => true } })

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      scenario_ids: [ scenario.id ]
    ).call
    row = result.find { |candidate| candidate.fetch(:id) == entry.id }

    assert_equal 100.to_d, row.fetch(:cash_delta)
    assert_equal 100.to_d, row.fetch(:liquid_delta)
  end

  test "non-transfer pending rows from tax advantaged accounts are budget neutral" do
    family = families(:dylan_family)
    accounts(:investment).accountable.update!(subtype: "401k")
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: -100, account: accounts(:investment))
    entry.transaction.update!(kind: "standard", category: categories(:income), extra: { "simplefin" => { "pending" => true } })

    result = Forecast::PendingEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: Date.current,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin))
    ).call
    row = result.find { |candidate| candidate.fetch(:id) == entry.id }

    assert_equal "none", row.fetch(:budget_flow_type)
    assert_equal 0.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:expected_spending)
    assert_equal 0.to_d, row.fetch(:pending_income)
    assert_equal 0.to_d, row.fetch(:pending_spending)
  end

  test "accepted future posted links are forecast through linked entry rows" do
    family = families(:dylan_family)
    event = family.forecast_events.create!(
      name: "Future linked bill",
      effect_type: "expense",
      behavior: "additive",
      amount: 100,
      currency: family.currency,
      starts_on: 10.days.from_now.to_date
    )
    entry = entries(:transaction)
    entry.update!(date: event.starts_on, amount: 100, account: accounts(:depository))
    entry.transaction.update!(kind: "standard", category: categories(:food_and_drink), extra: {})
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      accepted_links: [ link ]
    ).call

    row = result.first
    assert_equal "linked_future", row.fetch(:status)
    assert_equal 100.to_d, row.fetch(:expected_spending)
    assert_equal 0.to_d, row.fetch(:pending_spending)
    assert_equal link.id, row.fetch(:source_snapshot).fetch("forecast_event_link_id")
  end

  test "accepted future links still forecast from snapshots after linked entry deletion" do
    family = families(:dylan_family)
    event = family.forecast_events.create!(
      name: "Future linked deleted bill",
      effect_type: "expense",
      behavior: "additive",
      amount: 100,
      currency: family.currency,
      starts_on: 10.days.from_now.to_date
    )
    entry = entries(:transaction)
    entry.update!(date: event.starts_on, amount: 100, account: accounts(:depository))
    entry.transaction.update!(kind: "standard", category: categories(:food_and_drink), extra: {})
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    link.update_column(:entry_id, nil)

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      accepted_links: [ link.reload ]
    ).call

    row = result.first
    assert_equal "linked_future", row.fetch(:status)
    assert_equal 100.to_d, row.fetch(:expected_spending)
    assert_equal "deleted_entry_snapshot", row.fetch(:source_snapshot).fetch("source")
    assert_equal entry.id, row.fetch(:source_snapshot).fetch("id")
  end

  test "deleted linked cross-currency transfer snapshot uses endpoint dates" do
    family = families(:dylan_family)
    source_date = 10.days.from_now.to_date
    destination_date = source_date + 1.day
    accounts(:investment).update!(currency: "EUR")
    accounts(:depository).update!(currency: "KRW")
    event = family.forecast_events.create!(
      name: "Deleted linked FX transfer",
      effect_type: "transfer",
      behavior: "additive",
      account: accounts(:investment),
      destination_account: accounts(:depository),
      amount: 100,
      currency: "EUR",
      starts_on: source_date,
      source_metadata: { "destination_amount" => "120000", "destination_currency" => "KRW" }
    )
    outflow = Transaction.create!(kind: "funds_movement")
    inflow = Transaction.create!(kind: "funds_movement")
    outflow_entry = Entry.create!(account: accounts(:investment), entryable: outflow, name: "FX transfer out", date: source_date, amount: 100, currency: "EUR")
    Entry.create!(account: accounts(:depository), entryable: inflow, name: "FX transfer in", date: destination_date, amount: -120000, currency: "KRW")
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: outflow_entry,
      occurrence_on: source_date,
      link_type: "actual",
      status: "accepted"
    )
    link.update_column(:entry_id, nil)
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: source_date, cache: false)
      .returns(OpenStruct.new(rate: 1.1.to_d, date: source_date))
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "KRW", to: family.currency, date: destination_date, cache: false)
      .returns(OpenStruct.new(rate: 0.001.to_d, date: destination_date))

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      accepted_links: [ link.reload ]
    ).call

    row = result.first
    assert_equal source_date.iso8601, row.fetch(:source_snapshot).fetch("money").fetch("exchange_rate_date")
    assert_equal destination_date.iso8601, row.fetch(:source_snapshot).fetch("destination_money").fetch("exchange_rate_date")
  end

  test "deleted linked transfer snapshot recomputes transfer kind from endpoints" do
    family = families(:dylan_family)
    other_investment = family.accounts.create!(
      name: "Rollover target",
      balance: 0,
      currency: family.currency,
      accountable: Investment.new
    )
    category = family.categories.find_or_create_by!(name: Category.investment_contributions_name) do |new_category|
      new_category.color = "#0d9488"
      new_category.lucide_icon = "trending-up"
    end
    event = family.forecast_events.create!(
      name: "Deleted linked rollover",
      effect_type: "transfer",
      behavior: "additive",
      account: accounts(:investment),
      destination_account: other_investment,
      amount: 500,
      currency: family.currency,
      starts_on: 10.days.from_now.to_date
    )
    outflow = Transaction.create!(kind: "investment_contribution", category: category)
    inflow = Transaction.create!(kind: "funds_movement")
    outflow_entry = Entry.create!(account: accounts(:investment), entryable: outflow, name: "Rollover out", date: event.starts_on, amount: 500, currency: family.currency)
    Entry.create!(account: other_investment, entryable: inflow, name: "Rollover in", date: event.starts_on, amount: -500, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: outflow_entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    link.update_column(:entry_id, nil)

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      accepted_links: [ link.reload ]
    ).call

    row = result.first
    assert_equal "funds_movement", row.fetch(:transaction_kind)
    assert_equal "none", row.fetch(:budget_flow_type)
    assert_equal 0.to_d, row.fetch(:expected_spending)
  end

  test "deleted linked liability payment snapshot stays budget neutral" do
    family = families(:dylan_family)
    event = family.forecast_events.create!(
      name: "Deleted card payment",
      effect_type: "transfer",
      behavior: "additive",
      account: accounts(:depository),
      destination_account: accounts(:credit_card),
      amount: 200,
      currency: family.currency,
      starts_on: 10.days.from_now.to_date
    )
    outflow = Transaction.create!(kind: "cc_payment")
    inflow = Transaction.create!(kind: "funds_movement")
    Entry.create!(account: accounts(:depository), entryable: outflow, name: "Card payment out", date: event.starts_on, amount: 200, currency: family.currency)
    inflow_entry = Entry.create!(account: accounts(:credit_card), entryable: inflow, name: "Card payment in", date: event.starts_on, amount: -200, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: inflow_entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    link.update_column(:entry_id, nil)

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      accepted_links: [ link.reload ]
    ).call

    row = result.first
    assert_equal "cc_payment", row.fetch(:transaction_kind)
    assert_equal "none", row.fetch(:budget_flow_type)
    assert_equal 0.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:expected_spending)
  end

  test "deleted linked category snapshot does not become a live foreign key" do
    family = families(:dylan_family)
    category = family.categories.create!(name: "Temporary forecast category", color: "#64748b", lucide_icon: "receipt")
    event = family.forecast_events.create!(
      name: "Deleted category expense",
      effect_type: "expense",
      behavior: "additive",
      category: category,
      account: accounts(:depository),
      amount: 125,
      currency: family.currency,
      starts_on: 10.days.from_now.to_date
    )
    transaction = Transaction.create!(kind: "standard", category: category)
    entry = Entry.create!(account: accounts(:depository), entryable: transaction, name: "Future repair", date: event.starts_on, amount: 125, currency: family.currency)
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    event.update_column(:category_id, nil)
    transaction.update_column(:category_id, nil)
    category.destroy!
    link.update_column(:entry_id, nil)

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      accepted_links: [ link.reload ]
    ).call

    row = result.first
    assert_nil row.fetch(:category_id)
    assert_equal category.id, row.fetch(:source_snapshot).fetch("category").fetch("id")
  end

  test "accepted future linked transfer can be scoped by either endpoint" do
    family = families(:dylan_family)
    event = family.forecast_events.create!(
      name: "Future scoped transfer",
      effect_type: "transfer",
      behavior: "additive",
      account: accounts(:investment),
      destination_account: accounts(:depository),
      amount: 400,
      currency: family.currency,
      starts_on: 10.days.from_now.to_date
    )
    outflow = Transaction.create!(kind: "funds_movement")
    inflow = Transaction.create!(kind: "funds_movement")
    outflow_entry = Entry.create!(account: accounts(:investment), entryable: outflow, name: "Future transfer out", date: event.starts_on, amount: 400, currency: family.currency)
    Entry.create!(account: accounts(:depository), entryable: inflow, name: "Future transfer in", date: event.starts_on, amount: -400, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: outflow_entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id ], [ accounts(:depository).id ])

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: included_scope,
      accepted_links: [ link ]
    ).call

    row = result.first
    assert_equal "funds_movement", row.fetch(:transaction_kind)
    assert_equal 400.to_d, row.fetch(:cash_delta)
    assert_equal 400.to_d, row.fetch(:net_worth_delta)
  end

  test "accepted future linked cross-currency transfer inflow uses source and destination amounts" do
    family = families(:dylan_family)
    source_date = 10.days.from_now.to_date
    accounts(:investment).update!(currency: "EUR")
    accounts(:depository).update!(currency: "KRW")
    event = family.forecast_events.create!(
      name: "Future linked FX transfer",
      effect_type: "transfer",
      behavior: "additive",
      account: accounts(:investment),
      destination_account: accounts(:depository),
      amount: 100,
      currency: "EUR",
      starts_on: source_date,
      source_metadata: { "destination_amount" => "120000", "destination_currency" => "KRW" }
    )
    outflow = Transaction.create!(kind: "funds_movement")
    inflow = Transaction.create!(kind: "funds_movement")
    Entry.create!(account: accounts(:investment), entryable: outflow, name: "FX transfer out", date: source_date, amount: 100, currency: "EUR")
    inflow_entry = Entry.create!(account: accounts(:depository), entryable: inflow, name: "FX transfer in", date: source_date, amount: -120000, currency: "KRW")
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: inflow_entry,
      occurrence_on: source_date,
      link_type: "actual",
      status: "accepted"
    )
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: source_date, cache: false)
      .returns(OpenStruct.new(rate: 1.1.to_d, date: source_date))
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "KRW", to: family.currency, date: source_date, cache: false)
      .returns(OpenStruct.new(rate: 0.001.to_d, date: source_date))

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      accepted_links: [ link ]
    ).call

    row = result.first
    assert_equal 110.to_d, row.fetch(:amount)
    assert_equal "EUR", row.fetch(:native_currency)
    assert_equal "KRW", row.fetch(:source_snapshot).fetch("destination_money").fetch("native_currency")
    assert_equal 120.to_d, row.fetch(:cash_delta)
  end

  test "destination-only linked transfer does not convert excluded source endpoint" do
    family = families(:dylan_family)
    source_date = 10.days.from_now.to_date
    accounts(:investment).update!(currency: "EUR")
    accounts(:depository).update!(currency: "KRW")
    event = family.forecast_events.create!(
      name: "Destination-only FX transfer",
      effect_type: "transfer",
      behavior: "additive",
      account: accounts(:investment),
      destination_account: accounts(:depository),
      amount: 100,
      currency: "EUR",
      starts_on: source_date,
      source_metadata: { "destination_amount" => "120000", "destination_currency" => "KRW" }
    )
    outflow = Transaction.create!(kind: "funds_movement")
    inflow = Transaction.create!(kind: "funds_movement")
    Entry.create!(account: accounts(:investment), entryable: outflow, name: "FX transfer out", date: source_date, amount: 100, currency: "EUR")
    inflow_entry = Entry.create!(account: accounts(:depository), entryable: inflow, name: "FX transfer in", date: source_date, amount: -120000, currency: "KRW")
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: inflow_entry,
      occurrence_on: source_date,
      link_type: "actual",
      status: "accepted"
    )
    included_scope = Struct.new(:ids, :id_values).new([ accounts(:depository).id ], [ accounts(:depository).id ])
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: source_date, cache: false)
      .never
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "KRW", to: family.currency, date: source_date, cache: false)
      .twice
      .returns(OpenStruct.new(rate: 0.001.to_d, date: source_date))

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: included_scope,
      accepted_links: [ link ]
    ).call

    row = result.first
    assert_equal 120.to_d, row.fetch(:amount)
    assert_equal "KRW", row.fetch(:native_currency)
    assert_equal 120.to_d, row.fetch(:cash_delta)
  end

  test "accepted future linked rows use scenario liquidity settings" do
    family = families(:dylan_family)
    scenario = family.forecast_scenarios.create!(name: "Brokerage bridge", starts_on: 10.days.from_now.to_date, ends_on: 10.days.from_now.to_date)
    family.forecast_account_liquidity_settings.create!(
      forecast_scenario: scenario,
      account: accounts(:investment),
      liquidity_class: "cash",
      starts_on: scenario.starts_on,
      ends_on: scenario.ends_on
    )
    event = family.forecast_events.create!(
      name: "Future linked brokerage income",
      effect_type: "income",
      behavior: "additive",
      account: accounts(:investment),
      amount: 100,
      currency: family.currency,
      starts_on: scenario.starts_on,
      forecast_scenario: scenario
    )
    entry = entries(:transaction)
    entry.update!(date: event.starts_on, amount: -100, account: accounts(:investment))
    entry.transaction.update!(kind: "standard", category: categories(:income), extra: {})
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    result = Forecast::LinkedEntryInputBuilder.new(
      family: family,
      user: users(:family_admin),
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: users(:family_admin)),
      accepted_links: [ link ],
      scenario_ids: [ scenario.id ]
    ).call
    row = result.first

    assert_equal 100.to_d, row.fetch(:cash_delta)
    assert_equal 100.to_d, row.fetch(:liquid_delta)
  end
end
