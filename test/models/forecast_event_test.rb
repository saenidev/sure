require "test_helper"

class ForecastEventTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
  end

  test "validates account belongs to family" do
    other_account = accounts(:other_asset)
    other_account.update!(family: families(:empty), owner: users(:empty))

    event = @family.forecast_events.build(
      name: "Rent increase",
      effect_type: "expense",
      behavior: "additive",
      amount: 250,
      currency: "USD",
      starts_on: Date.current,
      account: other_account
    )

    assert_not event.valid?
    assert_includes event.errors[:account], "must belong to the forecast family"
  end

  test "stores recurrence metadata without expanding occurrences" do
    event = @family.forecast_events.build(
      name: "Temporary housing",
      effect_type: "expense",
      behavior: "additive",
      amount: 1800,
      currency: "USD",
      starts_on: Date.current,
      ends_on: 6.months.from_now.to_date,
      recurrence_rule: { "frequency" => "monthly", "day_of_month" => 15 }
    )

    assert event.valid?
  end

  test "legacy scenario-owned event defaults out of baseline and into its scenario membership" do
    scenario = @family.forecast_scenarios.create!(name: "Move", status: "active")

    event = scenario.forecast_events.create!(
      family: @family,
      name: "Scenario cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 100,
      currency: @family.currency,
      starts_on: Date.current
    )

    assert_not event.include_baseline?
    assert_equal [ scenario.id ], event.scenario_membership_ids
    assert event.applies_to_scenario_stack?([ scenario.id ])
    assert_not event.applies_to_scenario_stack?([])
  end

  test "accepts a valid weekly recurrence rule" do
    event = @family.forecast_events.build(
      name: "Weekly groceries",
      effect_type: "expense",
      behavior: "additive",
      amount: 120,
      currency: "USD",
      starts_on: Date.current,
      recurrence_rule: { "frequency" => "weekly", "interval" => 2 }
    )

    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test "rejects a recurrence interval below 1" do
    event = @family.forecast_events.build(
      name: "Zero interval",
      effect_type: "expense",
      behavior: "additive",
      amount: 120,
      currency: "USD",
      starts_on: Date.current,
      recurrence_rule: { "frequency" => "monthly", "interval" => 0, "day_of_month" => 1 }
    )

    assert_not event.valid?
    assert_includes event.errors[:recurrence_rule], "interval must be between 1 and 60"
  end

  test "rejects a recurrence interval above 60" do
    event = @family.forecast_events.build(
      name: "Huge interval",
      effect_type: "expense",
      behavior: "additive",
      amount: 120,
      currency: "USD",
      starts_on: Date.current,
      recurrence_rule: { "frequency" => "monthly", "interval" => 99, "day_of_month" => 1 }
    )

    assert_not event.valid?
    assert_includes event.errors[:recurrence_rule], "interval must be between 1 and 60"
  end

  test "rejects a monthly recurrence day_of_month outside 1-31" do
    event = @family.forecast_events.build(
      name: "Bad day",
      effect_type: "expense",
      behavior: "additive",
      amount: 120,
      currency: "USD",
      starts_on: Date.current,
      recurrence_rule: { "frequency" => "monthly", "interval" => 1, "day_of_month" => 45 }
    )

    assert_not event.valid?
    assert_includes event.errors[:recurrence_rule], "day_of_month must be between 1 and 31"
  end

  test "rejects unsupported recurrence metadata" do
    event = @family.forecast_events.build(
      name: "Odd cadence",
      effect_type: "expense",
      behavior: "additive",
      amount: 100,
      currency: "USD",
      starts_on: Date.current,
      recurrence_rule: { "frequency" => "daily" }
    )

    assert_not event.valid?
    assert_includes event.errors[:recurrence_rule], "frequency must be weekly or monthly"
  end

  test "amount based events require an amount and currency" do
    event = @family.forecast_events.build(
      name: "Potential loan draw",
      effect_type: "debt_drawdown",
      behavior: "additive",
      starts_on: Date.current
    )

    assert_not event.valid?
    assert_includes event.errors[:amount], "must be present for amount-based forecast events"
  end

  test "directional cash flow events require positive amounts" do
    event = @family.forecast_events.build(
      name: "Negative rent",
      effect_type: "expense",
      behavior: "additive",
      amount: -100,
      currency: "USD",
      starts_on: Date.current
    )

    assert_not event.valid?
    assert_includes event.errors[:amount], "must be greater than 0 for directional forecast events"
  end

  test "market shock can be signed" do
    event = @family.forecast_events.build(
      name: "Market drawdown",
      effect_type: "market_shock",
      behavior: "additive",
      amount: -1000,
      currency: "USD",
      starts_on: Date.current
    )

    assert event.valid?
  end

  test "transfer events require both accounts" do
    event = @family.forecast_events.build(
      name: "Move funds",
      effect_type: "transfer",
      behavior: "additive",
      amount: 500,
      currency: "USD",
      starts_on: Date.current,
      account: @account
    )

    assert_not event.valid?
    assert_includes event.errors[:destination_account], "must be present for transfer events"
  end

  test "event level linked status is not allowed" do
    event = @family.forecast_events.build(
      name: "Recurring bill",
      effect_type: "expense",
      behavior: "additive",
      amount: 100,
      currency: "USD",
      starts_on: Date.current,
      status: "linked"
    )

    assert_not event.valid?
    assert_includes event.errors[:status], "is not included in the list"
  end

  test "cross-currency transfer requires a positive numeric destination amount" do
    destination = accounts(:credit_card)
    destination.currency = "EUR" # in-memory only; exercises the cross-currency branch

    event = @family.forecast_events.build(
      name: "Move funds abroad",
      effect_type: "transfer",
      behavior: "additive",
      amount: 500,
      currency: "USD",
      starts_on: Date.current,
      account: @account,
      destination_account: destination,
      source_metadata: { "destination_amount" => "not-a-number", "destination_currency" => "EUR" }
    )

    assert_not event.valid?
    assert_includes event.errors[:source_metadata], "destination_amount must be a positive number for cross-currency transfer events"

    event.source_metadata = { "destination_amount" => "450.0", "destination_currency" => "EUR" }
    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test "debt_terms_override rejects an unparseable refinance effective_on" do
    event = @family.forecast_events.build(
      name: "Refinance loan",
      effect_type: "debt_terms_override",
      behavior: "additive",
      starts_on: Date.current,
      account: @account,
      source_metadata: { "refinance" => { "effective_on" => "soon", "new_annual_rate" => "12" } }
    )

    assert_not event.valid?
    assert_includes event.errors[:source_metadata], "refinance effective_on must be a valid date for debt_terms_override events"
  end

  test "debt_terms_override accepts a parseable refinance effective_on" do
    event = @family.forecast_events.build(
      name: "Refinance loan",
      effect_type: "debt_terms_override",
      behavior: "additive",
      starts_on: Date.current,
      account: @account,
      source_metadata: { "refinance" => { "effective_on" => Date.current.iso8601, "new_annual_rate" => "12" } }
    )

    assert event.valid?, event.errors.full_messages.to_sentence
  end
end
