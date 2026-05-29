require "test_helper"

class ForecastScenarioTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  test "parent scenario must belong to family" do
    parent = families(:empty).forecast_scenarios.create!(
      name: "Other family move",
      status: "active"
    )

    scenario = @family.forecast_scenarios.build(
      name: "Move abroad",
      status: "active",
      parent_scenario: parent
    )

    assert_not scenario.valid?
    assert_includes scenario.errors[:parent_scenario], "must belong to the forecast family"
  end

  test "display_order aliases the position column" do
    scenario = @family.forecast_scenarios.new(display_order: 7)
    assert_equal 7, scenario.position
    assert_equal 7, scenario.display_order
  end

  # --- duplicate_for_family! -------------------------------------------------

  test "duplicate deep-copies children re-scoped to family with reset status" do
    source = @family.forecast_scenarios.create!(
      name: "Big move",
      description: "Relocate next year",
      status: "active",
      approval_status: "approved",
      starts_on: Date.current.beginning_of_month,
      ends_on: Date.current.end_of_month + 6.months,
      color: "#0d9488",
      position: 3
    )

    source.forecast_events.create!(
      family: @family,
      name: "Signing bonus",
      effect_type: "income",
      behavior: "additive",
      amount: 5000,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )

    source.forecast_budget_overrides.create!(
      family: @family,
      period_start_on: Date.current.beginning_of_month,
      override_type: "expected_income",
      amount: 8000,
      currency: @family.currency,
      status: "active"
    )

    source.forecast_goals.create!(
      family: @family,
      name: "Keep 90 day runway",
      goal_type: "minimum_cash_runway",
      target_duration_days: 90,
      blocking_behavior: "warn",
      status: "active"
    )

    source.forecast_account_liquidity_settings.create!(
      family: @family,
      account: accounts(:depository),
      liquidity_class: "cash"
    )

    copy = nil
    assert_difference "@family.forecast_scenarios.count", 1 do
      copy = source.duplicate_for_family!(family: @family, user: @user)
    end

    assert_equal @family.id, copy.family_id
    assert_equal "disabled", copy.status, "copy is inert until toggled on"
    assert_equal "manual", copy.approval_status, "approval resets to manual"
    assert_equal source.id, copy.parent_scenario_id, "lineage preserved for same-family copy"
    assert_equal @user.id, copy.created_by_user_id
    assert_equal "#{source.name} (copy)", copy.name
    assert_equal source.starts_on, copy.starts_on
    assert_equal source.ends_on, copy.ends_on

    assert_equal 1, copy.forecast_events.count
    assert_equal 1, copy.forecast_budget_overrides.count
    assert_equal 1, copy.forecast_goals.count
    assert_equal 1, copy.forecast_account_liquidity_settings.count

    # Children are re-scoped to the family and carry an inert status, so the
    # duplicated active-uniqueness on budget overrides cannot collide.
    copied_event = copy.forecast_events.first
    assert_equal @family.id, copied_event.family_id
    assert_equal "disabled", copied_event.status

    copied_override = copy.forecast_budget_overrides.first
    assert_equal @family.id, copied_override.family_id
    assert_equal "disabled", copied_override.status

    copied_goal = copy.forecast_goals.first
    assert_equal @family.id, copied_goal.family_id
    assert_equal "disabled", copied_goal.status
  end

  test "duplicate succeeds for a scenario with zero children" do
    source = @family.forecast_scenarios.create!(name: "Empty scenario", status: "active")

    copy = nil
    assert_difference "@family.forecast_scenarios.count", 1 do
      copy = source.duplicate_for_family!(family: @family, user: @user)
    end

    assert_equal 0, copy.forecast_events.count
    assert_equal "disabled", copy.status
  end

  test "duplicate does not collide with the source active budget override" do
    period_start = Date.current.beginning_of_month
    source = @family.forecast_scenarios.create!(name: "Income bump", status: "active")
    source.forecast_budget_overrides.create!(
      family: @family,
      period_start_on: period_start,
      override_type: "expected_income",
      amount: 9000,
      currency: @family.currency,
      status: "active"
    )

    # The copy's overrides are disabled, so the active-uniqueness index that is
    # scoped per (period, scenario, type, category) is never violated.
    assert_nothing_raised do
      source.duplicate_for_family!(family: @family, user: @user)
    end
  end

  test "duplicate rolls back entirely when a child is invalid" do
    source = @family.forecast_scenarios.create!(name: "Bad child", status: "active")
    source.forecast_goals.create!(
      family: @family,
      name: "Runway goal",
      goal_type: "minimum_cash_runway",
      target_duration_days: 90,
      blocking_behavior: "warn",
      status: "active"
    )

    # Force a child copy to fail validation; the whole duplicate must roll back
    # rather than leave a partial copy.
    ForecastGoal.any_instance.stubs(:valid?).returns(false)

    assert_no_difference "@family.forecast_scenarios.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        source.duplicate_for_family!(family: @family, user: @user)
      end
    end
  end
end
