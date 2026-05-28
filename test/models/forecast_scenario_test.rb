require "test_helper"

class ForecastScenarioTest < ActiveSupport::TestCase
  test "parent scenario must belong to family" do
    parent = families(:empty).forecast_scenarios.create!(
      name: "Other family move",
      status: "active"
    )

    scenario = families(:dylan_family).forecast_scenarios.build(
      name: "Move abroad",
      status: "active",
      parent_scenario: parent
    )

    assert_not scenario.valid?
    assert_includes scenario.errors[:parent_scenario], "must belong to the forecast family"
  end
end
