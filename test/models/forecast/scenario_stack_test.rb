require "test_helper"

class Forecast::ScenarioStackTest < ActiveSupport::TestCase
  test "raises when requested scenario is disabled instead of returning baseline" do
    family = families(:dylan_family)
    scenario = family.forecast_scenarios.create!(
      name: "Paused move abroad",
      status: "disabled",
      starts_on: Date.current
    )

    error = assert_raises ArgumentError do
      Forecast::ScenarioStack.new(family: family, scenario_ids: [ scenario.id ]).call
    end

    assert_includes error.message, "Unknown or inactive forecast scenario ids"
  end
end
