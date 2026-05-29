require "test_helper"

class Forecast::LiquidityReclassificationBuilderTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository) # Depository -> default liquidity class "cash"
    @run_date = Date.new(2026, 1, 1)
    @periods = Forecast::PeriodBuilder.new(family: @family, start_on: @run_date, months: 12, daily_days: 90).call
    @account_rows = [ account_row(@account, balance: 5_000) ]
  end

  test "window starting on D moves cash balance into restricted on D" do
    setting_start = @run_date + 2.months
    @family.forecast_account_liquidity_settings.create!(
      account: @account,
      liquidity_class: "restricted",
      starts_on: setting_start
    )

    rows = build.call

    assert_equal 1, rows.size
    row = rows.first
    assert_equal setting_start, row.fetch(:date)
    assert_equal(-5_000.to_d, row.fetch(:cash_delta))
    assert_equal(-5_000.to_d, row.fetch(:liquid_delta)) # leaves cash AND the liquid superset
    assert_equal 0.to_d, row.fetch(:net_worth_delta)
    assert_equal 0.to_d, row.fetch(:expected_income)
    assert_equal 0.to_d, row.fetch(:expected_spending)

    meta = row.fetch(:source_snapshot)
    assert_equal "liquidity_reclassification", meta.fetch("type")
    assert_equal @account.id, meta.fetch("account_id")
    assert_equal "cash", meta.fetch("from_class")
    assert_equal "restricted", meta.fetch("to_class")
    assert_equal setting_start.iso8601, meta.fetch("effective_on")
  end

  test "window ending on E reverts to default on E.next_day" do
    setting_start = @run_date + 2.months
    setting_end = @run_date + 4.months
    @family.forecast_account_liquidity_settings.create!(
      account: @account,
      liquidity_class: "restricted",
      starts_on: setting_start,
      ends_on: setting_end
    )

    rows = build.call

    assert_equal 2, rows.size
    enter, revert = rows

    assert_equal setting_start, enter.fetch(:date)
    assert_equal "cash", enter.fetch(:source_snapshot).fetch("from_class")
    assert_equal "restricted", enter.fetch(:source_snapshot).fetch("to_class")

    assert_equal setting_end.next_day, revert.fetch(:date)
    assert_equal "restricted", revert.fetch(:source_snapshot).fetch("from_class")
    assert_equal "cash", revert.fetch(:source_snapshot).fetch("to_class")
    assert_equal 5_000.to_d, revert.fetch(:cash_delta)
    assert_equal 5_000.to_d, revert.fetch(:liquid_delta)
  end

  test "setting entirely outside the horizon emits nothing" do
    horizon_end = @periods.months.last.end_date
    @family.forecast_account_liquidity_settings.create!(
      account: @account,
      liquidity_class: "restricted",
      starts_on: horizon_end + 1.day
    )

    assert_equal [], build.call
  end

  test "overlapping baseline and scenario settings resolve to the scenario setting" do
    setting_start = @run_date + 2.months
    @family.forecast_account_liquidity_settings.create!(
      account: @account,
      liquidity_class: "restricted",
      starts_on: setting_start
    )
    scenario = @family.forecast_scenarios.create!(name: "Override", status: "active")
    @family.forecast_account_liquidity_settings.create!(
      forecast_scenario: scenario,
      account: @account,
      liquidity_class: "illiquid",
      starts_on: setting_start
    )

    rows = build(scenario_ids: [ scenario.id ]).call

    assert_equal 1, rows.size
    assert_equal "illiquid", rows.first.fetch(:source_snapshot).fetch("to_class")
    # illiquid is neither cash nor liquid, so it leaves both buckets.
    assert_equal(-5_000.to_d, rows.first.fetch(:cash_delta))
    assert_equal(-5_000.to_d, rows.first.fetch(:liquid_delta))
  end

  test "cash and liquid deltas net to zero over a closed window" do
    @family.forecast_account_liquidity_settings.create!(
      account: @account,
      liquidity_class: "restricted",
      starts_on: @run_date + 2.months,
      ends_on: @run_date + 4.months
    )

    rows = build.call

    assert_equal 0.to_d, rows.sum { |row| row.fetch(:cash_delta) }
    assert_equal 0.to_d, rows.sum { |row| row.fetch(:liquid_delta) }
    assert_equal 0.to_d, rows.sum { |row| row.fetch(:net_worth_delta) }
  end

  test "output is stable regardless of setting insertion order" do
    # Two non-overlapping windows for the same account inserted in two different orders
    # must produce identical output.
    windows = [
      { starts_on: @run_date + 2.months, ends_on: @run_date + 3.months },
      { starts_on: @run_date + 5.months, ends_on: @run_date + 6.months }
    ]

    forward = windows
    reverse = windows.reverse

    forward_rows = with_settings(forward) { build.call }
    reverse_rows = with_settings(reverse) { build.call }

    assert_equal serialize(forward_rows), serialize(reverse_rows)
    assert_equal 4, forward_rows.size # two enters + two reverts
    # Ordered by date ascending.
    assert_equal forward_rows.map { |row| row.fetch(:date) }.sort, forward_rows.map { |row| row.fetch(:date) }
  end

  test "no settings produces an empty result" do
    assert_equal [], build.call
  end

  test "default class matches the no-setting classification" do
    classifier = Forecast::LiquidityClassifier.new(family: @family, scenario_ids: [])
    assert_equal "cash", classifier.default_class(@account)
    assert_equal "debt", classifier.default_class(accounts(:loan))
    assert_equal "liquid", classifier.default_class(accounts(:investment))
    assert_equal "illiquid", classifier.default_class(accounts(:property))
  end

  private
    def build(scenario_ids: [])
      Forecast::LiquidityReclassificationBuilder.new(
        family: @family,
        scenario_ids: scenario_ids,
        accounts: @account_rows,
        periods: @periods,
        run_date: @run_date
      )
    end

    def account_row(account, balance:)
      {
        id: account.id,
        balance: balance.to_d,
        accountable_type: account.accountable_type,
        classification: account.classification,
        liquidity_class: "cash"
      }
    end

    def with_settings(windows)
      created = windows.map do |window|
        @family.forecast_account_liquidity_settings.create!(
          account: @account,
          liquidity_class: "restricted",
          starts_on: window.fetch(:starts_on),
          ends_on: window.fetch(:ends_on)
        )
      end
      yield
    ensure
      created.each(&:destroy)
    end

    def serialize(rows)
      rows.map { |row| [ row.fetch(:date), row.fetch(:cash_delta), row.fetch(:liquid_delta), row.fetch(:source_snapshot) ] }
    end
end
