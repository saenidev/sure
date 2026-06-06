# frozen_string_literal: true

require "test_helper"

# Unit tests for the pure 36-month period simulator. The simulator reads an
# ordered flow ledger plus opening balances from a source snapshot and produces
# per-period metric rows using the spec's flow ordering. It performs decimal-only
# arithmetic, converts foreign-currency flows via the snapshot FX table, and
# emits a structured `missing_fx_rate` plan issue (NOT an exception) when a rate
# is unavailable. See spec "Period Simulation", "Flow Ordering", "Currency And
# Rounding", and "Engine Invariants".
class Forecasts::Projection::PeriodSimulatorTest < ActiveSupport::TestCase
  Flow = Forecasts::Projection::FlowLedger::Flow

  HORIZON_START = Date.new(2026, 1, 1)

  def horizon(months: 36, starts_on: HORIZON_START)
    {
      starts_on: starts_on.iso8601,
      ends_on: (starts_on >> months).iso8601
    }
  end

  def source_snapshot(overrides = {})
    {
      as_of: "2026-01-01T00:00:00Z",
      reporting_currency: "USD",
      opening_balances: {
        liquid_cash: "10000.00",
        debt_balance: "0.00",
        portfolio_value: "0.00"
      },
      fx_rates: []
    }.merge(overrides)
  end

  def salary_flow(date:, amount: "6000.00", currency: "USD", key: nil)
    Flow.new(
      date: date,
      amount: amount,
      currency: currency,
      category: "income",
      direction: "inflow",
      source_kind: "salary",
      assumption_id: "salary-1",
      flow_key: key || "salary-#{date.iso8601}"
    )
  end

  def expense_flow(date:, amount: "4000.00", currency: "USD", key: nil)
    Flow.new(
      date: date,
      amount: amount,
      currency: currency,
      category: "spending",
      direction: "outflow",
      source_kind: "living_expense",
      assumption_id: "expense-1",
      flow_key: key || "expense-#{date.iso8601}"
    )
  end

  # Salary + living_expense fixture: $6000 income, $4000 spend, every month for
  # the full 36-month horizon.
  def salary_and_expense_ledger
    flows = []
    36.times do |i|
      date = HORIZON_START >> i
      flows << salary_flow(date: date)
      flows << expense_flow(date: date)
    end
    Forecasts::Projection::FlowLedger.new(flows)
  end

  def simulate(ledger:, snapshot: source_snapshot, hz: horizon, policy: {})
    Forecasts::Projection::PeriodSimulator.new(
      ledger: ledger,
      horizon: hz,
      source_snapshot: snapshot,
      reporting_currency: "USD",
      issue_policy: policy
    ).simulate
  end

  # --- Horizon shape -------------------------------------------------------

  test "produces 36 monthly period rows" do
    result = simulate(ledger: salary_and_expense_ledger)

    assert_equal 36, result.periods.length
    assert(result.periods.all? { |p| p[:granularity] == "month" })
    assert_equal "2026-01", result.periods.first[:key]
    assert_equal "2028-12", result.periods.last[:key]
  end

  test "each period carries calendar boundaries" do
    result = simulate(ledger: salary_and_expense_ledger)

    jan = result.periods.first
    assert_equal "2026-01-01", jan[:starts_on]
    assert_equal "2026-01-31", jan[:ends_on]

    feb = result.periods[1]
    assert_equal "2026-02-01", feb[:starts_on]
    assert_equal "2026-02-28", feb[:ends_on]
  end

  # --- Metric correctness --------------------------------------------------

  test "income and spending metrics reflect the flows in the period" do
    result = simulate(ledger: salary_and_expense_ledger)

    jan = result.periods.first
    assert_equal "6000.00", jan[:metrics][:income]
    assert_equal "4000.00", jan[:metrics][:spending]
  end

  test "liquid cash and net worth accumulate the running surplus" do
    result = simulate(ledger: salary_and_expense_ledger)

    # Opening 10000 + 2000 surplus in Jan.
    assert_equal "12000.00", result.periods.first[:metrics][:liquid_cash]
    assert_equal "12000.00", result.periods.first[:metrics][:net_worth]

    # 10000 + 2000 * 36 = 82000 by the last period.
    assert_equal "82000.00", result.periods.last[:metrics][:liquid_cash]
    assert_equal "82000.00", result.periods.last[:metrics][:net_worth]
  end

  test "net worth moves upward across the horizon for a saving plan" do
    result = simulate(ledger: salary_and_expense_ledger)

    first = BigDecimal(result.periods.first[:metrics][:net_worth])
    last = BigDecimal(result.periods.last[:metrics][:net_worth])

    assert last > first, "expected net worth to grow across the horizon"
  end

  test "runway_days is an integer derived from liquid cash and spending" do
    result = simulate(ledger: salary_and_expense_ledger)

    runway = result.periods.first[:metrics][:runway_days]
    assert_kind_of Integer, runway
    assert runway.positive?
  end

  test "debt and portfolio metrics default to the opening balances" do
    result = simulate(ledger: salary_and_expense_ledger)

    assert_equal "0.00", result.periods.first[:metrics][:debt_balance]
    assert_equal "0.00", result.periods.first[:metrics][:portfolio_value]
  end

  test "metric values are decimal strings, never floats" do
    result = simulate(ledger: salary_and_expense_ledger)

    metrics = result.periods.first[:metrics]
    %i[net_worth liquid_cash income spending debt_balance portfolio_value].each do |metric|
      assert_kind_of String, metrics[metric], "#{metric} must be a decimal string"
      assert_match(/\A-?\d+\.\d{2}\z/, metrics[metric], "#{metric} must be a 2dp decimal string")
    end
  end

  test "status is clean when there are no issues" do
    result = simulate(ledger: salary_and_expense_ledger)

    assert_equal "clean", result.status
    assert_empty result.issues
  end

  # --- Proration metadata --------------------------------------------------

  test "period rows carry proration metadata" do
    result = simulate(ledger: salary_and_expense_ledger)

    assert result.periods.first.key?(:proration)
    proration = result.periods.first[:proration]
    assert_equal 31, proration[:days_in_period]
    assert_equal true, proration[:full_period]
  end

  # --- Missing FX ----------------------------------------------------------

  def foreign_salary_ledger
    flows = []
    36.times do |i|
      date = HORIZON_START >> i
      flows << salary_flow(date: date, amount: "5000.00", currency: "EUR", key: "eur-#{date.iso8601}")
      flows << expense_flow(date: date)
    end
    Forecasts::Projection::FlowLedger.new(flows)
  end

  test "missing FX rate yields issue_limited status and a missing_fx_rate issue without raising" do
    result = nil
    assert_nothing_raised do
      result = simulate(ledger: foreign_salary_ledger)
    end

    assert_equal "issue_limited", result.status
    codes = result.issues.map(&:code)
    assert_includes codes, "missing_fx_rate"

    issue = result.issues.find { |i| i.code == "missing_fx_rate" }
    assert_equal "error", issue.severity
    assert_equal "source_snapshot", issue.source
    assert_equal "2026-01", issue.period
  end

  test "missing FX excludes the converted value so the flow is held out of metrics" do
    result = simulate(ledger: foreign_salary_ledger)

    # The EUR salary cannot convert, so only the USD spending applies; income is 0.
    jan = result.periods.first
    assert_equal "0.00", jan[:metrics][:income]
    assert_equal "4000.00", jan[:metrics][:spending]
  end

  test "present FX rate converts foreign flows into the reporting currency" do
    snapshot = source_snapshot(
      fx_rates: [
        { from: "EUR", to: "USD", date: "2026-01-01", rate: "1.10" }
      ]
    )

    # Single EUR salary in January only, with the rate present.
    ledger = Forecasts::Projection::FlowLedger.new([
      salary_flow(date: HORIZON_START, amount: "1000.00", currency: "EUR", key: "eur-jan")
    ])

    result = simulate(ledger: ledger, snapshot: snapshot)

    assert_equal "clean", result.status
    assert_equal "1100.00", result.periods.first[:metrics][:income]
  end
end
