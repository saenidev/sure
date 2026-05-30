require "test_helper"

class Forecast::EventEffectBuilderTest < ActiveSupport::TestCase
  test "debt drawdown changes cash and debt without pretending it is income" do
    family = families(:dylan_family)
    user = users(:family_admin)
    event = family.forecast_events.create!(
      name: "Possible bridge loan",
      effect_type: "debt_drawdown",
      behavior: "additive",
      amount: 5000,
      currency: family.currency,
      starts_on: Date.current
    )

    result = Forecast::EventEffectBuilder.new(
      family: family,
      user: user,
      events: [ event ],
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: []
    ).call

    row = result.first
    assert_equal event.id, row.fetch(:forecast_event_id)
    assert_equal 0.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:expected_spending)
    assert_equal 5000.to_d, row.fetch(:cash_delta)
    assert_equal 5000.to_d, row.fetch(:debt_delta)
    assert_equal 0.to_d, row.fetch(:net_worth_delta)
  end

  test "standard income event in investment account changes liquid portfolio instead of cash" do
    family = families(:dylan_family)
    user = users(:family_admin)
    event = family.forecast_events.create!(
      name: "Taxable brokerage dividend",
      effect_type: "income",
      behavior: "additive",
      account: accounts(:investment),
      amount: 125,
      currency: family.currency,
      starts_on: Date.current
    )

    result = Forecast::EventEffectBuilder.new(
      family: family,
      user: user,
      events: [ event ],
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: []
    ).call

    row = result.first
    assert_equal 125.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:cash_delta)
    assert_equal 125.to_d, row.fetch(:liquid_delta)
    assert_equal 125.to_d, row.fetch(:portfolio_delta)
    assert_equal 125.to_d, row.fetch(:net_worth_delta)
  end

  test "standard event liquidity classification uses event date" do
    family = families(:dylan_family)
    user = users(:family_admin)
    scenario = family.forecast_scenarios.create!(
      name: "Unlock investment cash",
      status: "active",
      starts_on: 1.month.from_now.to_date
    )
    family.forecast_account_liquidity_settings.create!(
      forecast_scenario: scenario,
      account: accounts(:investment),
      liquidity_class: "cash"
    )
    event = family.forecast_events.create!(
      forecast_scenario: scenario,
      name: "Future brokerage distribution",
      effect_type: "income",
      behavior: "additive",
      account: accounts(:investment),
      amount: 125,
      currency: family.currency,
      starts_on: scenario.starts_on
    )

    result = Forecast::EventEffectBuilder.new(
      family: family,
      user: user,
      events: [ event ],
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [ scenario.id ]
    ).call

    row = result.first
    assert_equal scenario.starts_on, row.fetch(:date)
    assert_equal 125.to_d, row.fetch(:cash_delta)
    assert_equal 125.to_d, row.fetch(:liquid_delta)
    assert_equal 125.to_d, row.fetch(:portfolio_delta)
  end

  test "transfer event from included source to excluded destination affects scoped balances" do
    family = families(:dylan_family)
    user = users(:family_admin)
    event = family.forecast_events.create!(
      name: "Outside brokerage transfer",
      effect_type: "transfer",
      behavior: "additive",
      account: accounts(:depository),
      destination_account: accounts(:investment),
      amount: 400,
      currency: family.currency,
      starts_on: Date.current
    )

    result = Forecast::EventEffectBuilder.new(
      family: family,
      user: user,
      events: [ event ],
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_ids: [ accounts(:depository).id ]
    ).call

    row = result.first
    assert_equal "investment_contribution", row.fetch(:transaction_kind)
    assert_equal "expense", row.fetch(:budget_flow_type)
    assert_equal(-400.to_d, row.fetch(:cash_delta))
    assert_equal(-400.to_d, row.fetch(:net_worth_delta))
  end

  test "one time scenario events dated before the scenario window are clamped to the window start" do
    family = families(:dylan_family)
    user = users(:family_admin)
    scenario = family.forecast_scenarios.create!(
      name: "Move abroad",
      status: "active",
      starts_on: 1.month.from_now.to_date,
      ends_on: 1.month.from_now.to_date
    )
    event = family.forecast_events.create!(
      forecast_scenario: scenario,
      name: "Relocation deposit",
      effect_type: "expense",
      behavior: "additive",
      amount: 2000,
      currency: family.currency,
      starts_on: Date.current
    )

    result = Forecast::EventEffectBuilder.new(
      family: family,
      user: user,
      events: [ event ],
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [ scenario.id ]
    ).call

    # A planned one-time expense must never silently vanish for being dated
    # before its scenario window. It fires on the first valid day (the scenario
    # start) instead of being dropped.
    assert_equal 1, result.size
    row = result.first
    assert_equal scenario.starts_on, row.fetch(:date)
    assert_equal 2000.to_d, row.fetch(:expected_spending)
  end

  test "one time event dated before the run start is clamped forward to the run start" do
    family = families(:dylan_family)
    user = users(:family_admin)
    event = family.forecast_events.create!(
      name: "Overdue planned expense",
      effect_type: "expense",
      behavior: "additive",
      amount: 5000,
      currency: family.currency,
      starts_on: 1.day.ago.to_date
    )

    result = Forecast::EventEffectBuilder.new(
      family: family,
      user: user,
      events: [ event ],
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: []
    ).call

    assert_equal 1, result.size
    row = result.first
    assert_equal Date.current, row.fetch(:date)
    assert_equal 5000.to_d, row.fetch(:expected_spending)
  end

  test "one time scenario events dated after the scenario window are dropped" do
    family = families(:dylan_family)
    user = users(:family_admin)
    scenario = family.forecast_scenarios.create!(
      name: "Single day scenario",
      status: "active",
      starts_on: 1.month.from_now.to_date,
      ends_on: 1.month.from_now.to_date
    )
    event = family.forecast_events.create!(
      forecast_scenario: scenario,
      name: "Too-late expense",
      effect_type: "expense",
      behavior: "additive",
      amount: 2000,
      currency: family.currency,
      starts_on: 2.months.from_now.to_date
    )

    result = Forecast::EventEffectBuilder.new(
      family: family,
      user: user,
      events: [ event ],
      start_on: Date.current,
      end_on: 36.months.from_now.to_date,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [ scenario.id ]
    ).call

    assert_empty result
  end

  test "accepted link suppresses only the linked recurring occurrence" do
    family = families(:dylan_family)
    user = users(:family_admin)
    event = family.forecast_events.create!(
      name: "Possible monthly stipend",
      effect_type: "income",
      behavior: "additive",
      amount: 1000,
      currency: family.currency,
      starts_on: Date.current,
      recurrence_rule: { "frequency" => "monthly", "day_of_month" => Date.current.day }
    )
    link = family.forecast_event_links.create!(
      forecast_event: event,
      entry: entries(:transaction),
      occurrence_on: Date.current,
      link_type: "actual",
      status: "accepted"
    )

    result = Forecast::EventEffectBuilder.new(
      family: family,
      user: user,
      events: [ event ],
      start_on: Date.current,
      end_on: Date.current.next_month,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      accepted_links: [ link ]
    ).call

    assert_equal [ Date.current.next_month ], result.map { |row| row.fetch(:date) }
  end
end
