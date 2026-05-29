require "test_helper"

class Forecast::WorkspaceTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  test "empty family with no planning data and no runs is onboarding" do
    @family.forecast_run_groups.delete_all
    @family.forecast_scenarios.delete_all
    @family.forecast_events.delete_all
    @family.forecast_goals.delete_all

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal :onboarding, workspace.status
    assert workspace.onboarding?
    assert_nil workspace.latest_group
    assert_nil workspace.run_group
  end

  test "planning data but no completed run is ready" do
    @family.forecast_run_groups.delete_all
    @family.forecast_scenarios.create!(name: "Job change", status: "active", approval_status: "manual")

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal :ready, workspace.status
    assert workspace.ready?
    assert workspace.planning_data?
  end

  test "non-terminal latest group (pending/running) is treated as ready" do
    @family.forecast_run_groups.delete_all
    @family.forecast_run_groups.create!(
      user: @user,
      name: "In flight",
      run_type: "manual",
      status: "running",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal :ready, workspace.status
  end

  test "latest completed group surfaces has_run and returns that group" do
    @family.forecast_run_groups.delete_all
    group = build_completed_run_group(family: @family, user: @user, runs: 2)

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal :has_run, workspace.status
    assert workspace.has_run?
    assert_equal group, workspace.run_group
    assert_equal 2, workspace.scenario_stack_count
    assert_equal group.horizon_start_on, workspace.horizon_start_on
    assert_equal group.horizon_end_on, workspace.horizon_end_on
    assert_not_nil workspace.generated_at
  end

  test "latest failed group surfaces failed status and error message" do
    @family.forecast_run_groups.delete_all
    build_failed_run_group(family: @family, user: @user, error_message: "MoneyConverter::MissingRate: USD->EUR")

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal :failed, workspace.status
    assert workspace.failed?
    assert_equal "MoneyConverter::MissingRate: USD->EUR", workspace.error_message
    assert_nil workspace.run_group
  end

  test "newer failed group supersedes an older completed group (most recent wins)" do
    @family.forecast_run_groups.delete_all
    build_completed_run_group(family: @family, user: @user, created_at: 3.days.ago)
    build_failed_run_group(family: @family, user: @user, error_message: "boom", created_at: 1.hour.ago)

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal :failed, workspace.status
    assert_equal "boom", workspace.error_message
  end

  test "older failed group does not hide a newer completed group" do
    @family.forecast_run_groups.delete_all
    build_failed_run_group(family: @family, user: @user, created_at: 3.days.ago)
    newer = build_completed_run_group(family: @family, user: @user, created_at: 1.hour.ago)

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal :has_run, workspace.status
    assert_equal newer, workspace.run_group
  end

  test "eager-loads forecast_runs without N+1 when summarizing a run" do
    @family.forecast_run_groups.delete_all
    build_completed_run_group(family: @family, user: @user, runs: 3)

    workspace = Forecast::Workspace.new(family: @family)
    group = workspace.latest_group

    # Runs were eager-loaded with the group, so reading them adds no queries.
    assert_no_queries do
      group.forecast_runs.to_a
      workspace.scenario_stack_count
    end
  end

  test "only the current family's run groups are considered" do
    @family.forecast_run_groups.delete_all
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    # Other family has the most recent global group.
    build_completed_run_group(family: other_family, user: users(:empty), created_at: 1.minute.ago)

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal :onboarding, workspace.status
    assert_nil workspace.latest_group
  end
end
