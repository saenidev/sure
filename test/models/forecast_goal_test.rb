require "test_helper"

class ForecastGoalTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "runway goal can block scenarios" do
    goal = @family.forecast_goals.build(
      name: "Keep six months runway",
      goal_type: "minimum_cash_runway",
      target_duration_days: 180,
      required: true,
      blocking_behavior: "blocks_scenario"
    )

    assert goal.valid?
  end

  test "goal date window must be ordered" do
    goal = @family.forecast_goals.build(
      name: "Move abroad buffer",
      goal_type: "minimum_cash_balance",
      target_amount: 10_000,
      currency: @family.currency,
      starts_on: 2.months.from_now.to_date,
      ends_on: 1.month.from_now.to_date
    )

    assert_not goal.valid?
    assert_includes goal.errors[:ends_on], "must be on or after starts_on"
  end
end
