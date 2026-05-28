require "test_helper"

class ForecastAccountLiquiditySettingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "account must belong to family" do
    account = accounts(:other_asset)
    account.update!(family: families(:empty), owner: users(:empty))

    setting = @family.forecast_account_liquidity_settings.build(
      account: account,
      liquidity_class: "cash"
    )

    assert_not setting.valid?
    assert_includes setting.errors[:account], "must belong to the forecast family"
  end

  test "overlapping windows are rejected per account and scenario" do
    scenario = @family.forecast_scenarios.create!(name: "Move cash", status: "active", starts_on: Date.current)
    @family.forecast_account_liquidity_settings.create!(
      forecast_scenario: scenario,
      account: accounts(:investment),
      liquidity_class: "cash",
      starts_on: Date.current,
      ends_on: 1.month.from_now.to_date
    )

    duplicate_window = @family.forecast_account_liquidity_settings.build(
      forecast_scenario: scenario,
      account: accounts(:investment),
      liquidity_class: "restricted",
      starts_on: 2.weeks.from_now.to_date,
      ends_on: 2.months.from_now.to_date
    )

    assert_not duplicate_window.valid?
    assert_includes duplicate_window.errors[:base], "liquidity setting overlaps another setting for this account and scenario"
  end
end
