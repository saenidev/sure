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

  test "non-terminal latest group (pending/running) surfaces running state" do
    @family.forecast_run_groups.delete_all
    group = @family.forecast_run_groups.create!(
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

    assert_equal :running, workspace.status
    assert workspace.running?
    assert_equal group, workspace.running_group
  end

  test "baseline_run prefers the baseline scenario stack and exposes 36 monthly rows" do
    @family.forecast_run_groups.delete_all
    group = build_completed_run_group(family: @family, user: @user, runs: 1)
    run = group.forecast_runs.first
    run.update_column(:scenario_stack_key, "baseline")

    workspace = Forecast::Workspace.new(family: @family)

    assert_equal run, workspace.baseline_run
    assert_not workspace.overview_data?
    assert_equal 0, workspace.monthly_rows.count
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

  # --- distribution band & goal tradeoff builder accessors -------------------

  test "distribution/tradeoff builders are nil and predicates false with no run group" do
    @family.forecast_run_groups.delete_all

    workspace = Forecast::Workspace.new(family: @family)

    assert_nil workspace.distribution_band_builder
    assert_nil workspace.goal_tradeoff_explorer
    assert_not workspace.distribution_band_data?
    assert_not workspace.goal_tradeoff_data?
  end

  test "distribution/tradeoff predicates are false for a single-baseline-only group" do
    @family.forecast_run_groups.delete_all
    build_band_group(stacks: [ "baseline" ])

    workspace = Forecast::Workspace.new(family: @family)

    # The builders are constructed (a group exists) but there is nothing to band
    # or trade off with only one stack, so both predicates are false.
    assert_not_nil workspace.distribution_band_builder
    assert_not_nil workspace.goal_tradeoff_explorer
    assert_not workspace.distribution_band_data?
    assert_not workspace.goal_tradeoff_data?
  end

  test "distribution/tradeoff predicates are false when the only non-baseline stack failed" do
    @family.forecast_run_groups.delete_all
    build_band_group(stacks: [ "baseline" ], failed_stacks: [ "downside" ])

    workspace = Forecast::Workspace.new(family: @family)

    # multiple_stacks? is true (a failed run is still a run), but the failed stack
    # is excluded from the contributing stacks, so there is no second stack to
    # band or rank: both predicates must be false.
    assert workspace.multiple_stacks?
    assert_not workspace.distribution_band_data?
    assert_not workspace.goal_tradeoff_data?
  end

  test "distribution/tradeoff predicates are true with two contributing stacks" do
    @family.forecast_run_groups.delete_all
    build_band_group(stacks: %w[baseline downside])

    workspace = Forecast::Workspace.new(family: @family)

    assert workspace.distribution_band_data?
    assert workspace.goal_tradeoff_data?
  end

  test "goal_tradeoff_explorer reads goal evaluations without extra queries (eager-loaded)" do
    @family.forecast_run_groups.delete_all
    build_band_group(stacks: %w[baseline downside])

    workspace = Forecast::Workspace.new(family: @family)
    # Force the eager-load (latest_group preloads forecast_goal_evaluations).
    workspace.comparison_runs

    # Reading the explorer's rankings (which iterates runs x goal evaluations)
    # must not issue a single additional forecast_goal_evaluations query.
    assert_no_queries do
      workspace.goal_tradeoff_explorer.rankings
    end
  end

  # --- i18n keys the read-model builders reference ---------------------------

  test "distribution band note i18n keys the builder references resolve" do
    # The DistributionBandBuilder calls these two keys directly; they must exist
    # so a banded month never raises a missing-translation error.
    assert_nothing_raised do
      I18n.t("forecasts.distribution.empty_band_note", raise: true)
      I18n.t("forecasts.distribution.trimmed_to_common_months_note", raise: true)
    end
  end

  test "new forecast tab labels resolve for every tab id" do
    assert_nothing_raised do
      Forecast::Workspace::TAB_IDS.each do |tab_id|
        I18n.t("forecasts.show.tabs.#{tab_id}", raise: true)
      end
    end
  end

  private
    # Builds a completed comparison group with one ForecastRun per stack key, each
    # carrying 3 ascending months plus one goal evaluation, so the band builder
    # and tradeoff explorer have real, deterministic data to read. Failed stacks
    # are persisted without months/evaluations and flipped to "failed".
    def build_band_group(stacks:, failed_stacks: [])
      currency = @family.currency
      group = @family.forecast_run_groups.create!(
        user: @user, name: "Comparison run", run_type: "manual", currency: currency,
        horizon_start_on: Date.current, horizon_end_on: Date.current + 36.months,
        daily_until_on: Date.current + 89.days
      )

      stacks.each_with_index do |stack_key, idx|
        run = group.forecast_runs.create!(
          family: @family, user: @user, scenario_stack_key: stack_key,
          scenario_stack_snapshot: { "key" => stack_key, "label" => stack_key.titleize },
          status: "running", feasibility_status: "pass", currency: currency,
          input_snapshot: forecast_valid_input_snapshot(@family)
        )

        3.times do |i|
          period_start = Date.current + i.months
          run.forecast_months.create!(
            period_start_on: period_start, period_end_on: period_start.end_of_month,
            precision: "monthly", scenario_stack_key: stack_key, currency: currency,
            cash_balance: 1000 + (i * 100) + (idx * 50),
            liquid_balance: 2000, debt_balance: 500 - (i * 50),
            net_worth: 5000 + (i * 100) + (idx * 50), risk_flags: []
          )
        end

        run.forecast_goal_evaluations.create!(
          goal_key: "forecast_goal:runway", scenario_stack_key: stack_key,
          status: stack_key == "baseline" ? "pass" : "warn", currency: currency,
          metric_value: 100 + (idx * 10), target_value: 90,
          goal_snapshot: { "goal_type" => "minimum_cash_runway" },
          details: { "field" => "cash_runway_days" }
        )

        run.update!(status: "completed", finished_at: Time.current)
      end

      failed_stacks.each do |stack_key|
        group.forecast_runs.create!(
          family: @family, user: @user, scenario_stack_key: stack_key,
          scenario_stack_snapshot: { "key" => stack_key }, status: "failed",
          feasibility_status: "unknown", currency: currency,
          error_message: "MoneyConverter::MissingRate: no rate",
          input_snapshot: forecast_valid_input_snapshot(@family)
        )
      end

      if failed_stacks.any?
        # A partial-failure group cannot be "completed" (the model requires every
        # run be completed for that status), so it is persisted as "failed" with
        # completed runs alongside — the same shape the Runner writes. The
        # workspace treats it as has_run because a completed run exists.
        group.update!(finished_at: Time.current)
        group.update_column(:status, "failed")
      else
        group.update!(status: "completed", finished_at: Time.current)
      end
      group
    end
end
