require "test_helper"
require "ostruct"

class Forecast::InputBuilderTest < ActiveSupport::TestCase
  test "builds an input packet without creating budgets" do
    before_count = Budget.count

    result = Forecast::InputBuilder.new(
      family: families(:dylan_family),
      user: users(:family_admin),
      scenario_ids: [],
      start_on: Date.current
    ).call

    assert_equal before_count, Budget.count
    assert_equal "baseline", result.scenario_stack.key
    assert result.accounts.any?
    assert result.source_data_versions.key?("accounts_max_updated_at")
  end

  test "normalizes amount goals into family currency with a money snapshot" do
    family = families(:dylan_family)
    family.forecast_goals.create!(
      name: "Emergency buffer",
      goal_type: "minimum_cash_balance",
      target_amount: 100,
      currency: "EUR",
      required: true
    )
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: Date.current, cache: false)
      .returns(OpenStruct.new(rate: 2.to_d, date: Date.current))

    result = Forecast::InputBuilder.new(
      family: family,
      user: users(:family_admin),
      scenario_ids: [],
      start_on: Date.current
    ).call
    goal = result.goals.find { |row| row.fetch("name") == "Emergency buffer" }

    assert_equal 200.to_d, goal.fetch("target_amount").to_d
    assert_equal family.currency, goal.fetch("currency")
    assert_equal "EUR", goal.fetch("target_money_snapshot").fetch("native_currency")
  end

  test "builds dated liquidity reclassification effects from future setting windows" do
    family = families(:dylan_family)
    account = accounts(:depository)
    account.update!(balance: 5_000)
    start_on = Date.current
    setting_start = start_on + 4.months
    family.forecast_account_liquidity_settings.create!(
      account: account,
      liquidity_class: "restricted",
      starts_on: setting_start
    )

    result = Forecast::InputBuilder.new(
      family: family,
      user: users(:family_admin),
      scenario_ids: [],
      start_on: start_on
    ).call

    row = result.reclassifications.find { |candidate| candidate.fetch(:account_id) == account.id }

    assert row.present?
    assert_equal setting_start, row.fetch(:date)
    assert_equal "liquidity_reclassification", row.fetch(:effect_type)
    assert_equal "cash", row.fetch(:source_snapshot).fetch("from_class")
    assert_equal "restricted", row.fetch(:source_snapshot).fetch("to_class")
    # Balance-neutral: leaves the cash bucket without creating spending.
    assert_operator row.fetch(:cash_delta), :<, 0.to_d
    assert_equal 0.to_d, row.fetch(:net_worth_delta)
  end

  test "no liquidity setting windows yields an empty reclassification stream" do
    result = Forecast::InputBuilder.new(
      family: families(:dylan_family),
      user: users(:family_admin),
      scenario_ids: [],
      start_on: Date.current
    ).call

    assert_equal [], result.reclassifications
  end

  test "accepted future link remains in inputs after source event deletion" do
    family = families(:dylan_family)
    event = family.forecast_events.create!(
      name: "Future linked deleted event",
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
    event.destroy!

    result = Forecast::InputBuilder.new(
      family: family,
      user: users(:family_admin),
      scenario_ids: [],
      start_on: Date.current
    ).call
    row = result.pending_entries.find { |candidate| candidate.fetch(:source_snapshot).fetch("forecast_event_link_id", nil) == link.id }

    assert_equal "linked_future", row.fetch(:status)
    assert_equal 100.to_d, row.fetch(:expected_spending)
  end

  test "accepted-link future/past classification follows the run date, not the wall clock" do
    family = families(:dylan_family)
    run_start = Date.new(2026, 6, 1)
    occurrence = Date.new(2026, 9, 1) # after the run start -> future relative to the run
    event = family.forecast_events.create!(
      name: "Planned repair",
      effect_type: "expense",
      behavior: "additive",
      amount: 100,
      currency: family.currency,
      starts_on: occurrence
    )
    transaction = Transaction.create!(kind: "standard", category: categories(:food_and_drink))
    entry = Entry.create!(
      account: accounts(:depository),
      entryable: transaction,
      name: "Repair",
      date: occurrence,
      amount: 100,
      currency: family.currency
    )
    family.forecast_event_links.create!(
      forecast_event: event,
      entry: entry,
      occurrence_on: occurrence,
      link_type: "actual",
      status: "accepted"
    )

    snapshot = lambda do
      result = Forecast::InputBuilder.new(family: family, user: users(:family_admin), scenario_ids: [], start_on: run_start).call
      [
        result.events.any? { |row| row.fetch(:forecast_event_id) == event.id },
        result.pending_entries.map { |row| row.fetch(:status) }.sort
      ]
    end

    # Same run date, two different wall clocks straddling the occurrence date. With a
    # wall-clock leak the occurrence flips from "future" to "past" between runs; keyed
    # off the run date it is deterministically the same.
    before_occurrence = travel_to(Date.new(2026, 6, 15)) { snapshot.call }
    after_occurrence = travel_to(Date.new(2026, 9, 15)) { snapshot.call }

    assert_equal before_occurrence, after_occurrence,
      "accepted-link future/past handling must depend on start_on, not Date.current"
  end

  test "accepted link to excluded future entry does not suppress forecast event" do
    family = families(:dylan_family)
    event = family.forecast_events.create!(
      name: "Potential repair",
      effect_type: "expense",
      behavior: "additive",
      amount: 100,
      currency: family.currency,
      starts_on: 10.days.from_now.to_date
    )
    transaction = Transaction.create!(kind: "standard", category: categories(:food_and_drink))
    entry = Entry.create!(
      account: accounts(:depository),
      entryable: transaction,
      name: "Excluded repair",
      date: event.starts_on,
      amount: 100,
      currency: family.currency
    )
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    entry.update!(excluded: true)

    result = Forecast::InputBuilder.new(
      family: family,
      user: users(:family_admin),
      scenario_ids: [],
      start_on: Date.current
    ).call

    assert result.events.any? { |row| row.fetch(:forecast_event_id) == event.id }
    assert_empty result.pending_entries.select { |row| row.fetch(:source_snapshot, {}).fetch("forecast_event_link_id", nil) == link.id }
  end

  test "accepted link to ignored pending transfer side suppresses when canonical side is modeled" do
    family = families(:dylan_family)
    event = family.forecast_events.create!(
      name: "Pending card payment",
      effect_type: "transfer",
      behavior: "additive",
      account: accounts(:depository),
      destination_account: accounts(:credit_card),
      amount: 200,
      currency: family.currency,
      starts_on: Date.current
    )
    outflow = Transaction.create!(kind: "cc_payment", extra: { "simplefin" => { "pending" => true } })
    inflow = Transaction.create!(kind: "funds_movement", extra: { "simplefin" => { "pending" => true } })
    Entry.create!(account: accounts(:depository), entryable: outflow, name: "Card payment out", date: Date.current, amount: 200, currency: family.currency)
    inflow_entry = Entry.create!(account: accounts(:credit_card), entryable: inflow, name: "Card payment in", date: Date.current, amount: -200, currency: family.currency)
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow)
    family.forecast_event_links.create!(
      forecast_event: event,
      entry: inflow_entry,
      occurrence_on: event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    result = Forecast::InputBuilder.new(
      family: family,
      user: users(:family_admin),
      scenario_ids: [],
      start_on: Date.current
    ).call

    assert_empty result.events.select { |row| row.fetch(:forecast_event_id) == event.id }
    assert result.pending_entries.any? { |row| row.fetch(:transaction_kind) == "cc_payment" }
  end
end
