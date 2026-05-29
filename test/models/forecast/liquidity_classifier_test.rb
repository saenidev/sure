require "test_helper"

class Forecast::LiquidityClassifierTest < ActiveSupport::TestCase
  test "scenario liquidity setting applies only in its date window" do
    family = families(:dylan_family)
    scenario = family.forecast_scenarios.create!(name: "Unlock account", status: "active", starts_on: 1.month.from_now.to_date)
    setting = family.forecast_account_liquidity_settings.create!(
      forecast_scenario: scenario,
      account: accounts(:investment),
      liquidity_class: "cash"
    )

    classifier = Forecast::LiquidityClassifier.new(family: family, scenario_ids: [ scenario.id ])

    assert_equal "liquid", classifier.call(setting.account, on: Date.current)
    assert_equal "cash", classifier.call(setting.account, on: 1.month.from_now.to_date)
  end

  test "scenario liquidity setting is clamped to the scenario window" do
    family = families(:dylan_family)
    scenario = family.forecast_scenarios.create!(
      name: "Short bridge",
      status: "active",
      starts_on: 1.month.from_now.to_date,
      ends_on: 2.months.from_now.to_date
    )
    setting = family.forecast_account_liquidity_settings.create!(
      forecast_scenario: scenario,
      account: accounts(:investment),
      liquidity_class: "cash",
      starts_on: Date.current,
      ends_on: 3.months.from_now.to_date
    )

    classifier = Forecast::LiquidityClassifier.new(family: family, scenario_ids: [ scenario.id ])

    assert_equal "liquid", classifier.call(setting.account, on: Date.current)
    assert_equal "cash", classifier.call(setting.account, on: 1.month.from_now.to_date)
    assert_equal "liquid", classifier.call(setting.account, on: 3.months.from_now.to_date)
  end

  test "call requires an explicit on: date so it cannot silently read the wall clock" do
    classifier = Forecast::LiquidityClassifier.new(family: families(:dylan_family), scenario_ids: [])

    assert_raises(ArgumentError) { classifier.call(accounts(:depository)) }
    assert_equal "cash", classifier.call(accounts(:depository), on: Date.current)
  end
end
