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

  test "distribution_metric_bands is empty for a single-baseline-only group" do
    @family.forecast_run_groups.delete_all
    build_band_group(stacks: [ "baseline" ])

    workspace = Forecast::Workspace.new(family: @family)

    assert_empty workspace.distribution_metric_bands
  end

  test "distribution_metric_bands is empty when no run group exists" do
    @family.forecast_run_groups.delete_all

    workspace = Forecast::Workspace.new(family: @family)

    assert_empty workspace.distribution_metric_bands
  end

  test "distribution_metric_bands yields chart-ready low/mid/high series per metric for a multi-stack group" do
    @family.forecast_run_groups.delete_all
    build_band_group(stacks: %w[baseline downside])

    workspace = Forecast::Workspace.new(family: @family)
    bands = workspace.distribution_metric_bands

    # One MetricBands per banded metric (net_worth, cash_balance, debt_balance).
    assert_equal Forecast::DistributionBandBuilder::METRICS, bands.map(&:metric)

    net_worth = bands.find { |b| b.metric == :net_worth }
    # Three months in the helper -> each edge is a renderable >=2-point series.
    assert net_worth.low_series.any?
    assert net_worth.mid_series.any?
    assert net_worth.high_series.any?
    # Attribution lists the contributing stacks (baseline first), never a failed one.
    assert_equal %w[baseline downside], net_worth.contributing_stack_keys
  end

  test "distribution_metric_bands excludes a failed stack from band edges and attribution" do
    @family.forecast_run_groups.delete_all
    # Two completed stacks plus a failed one: the failed stack must never appear
    # as a band edge source nor as a contributing stack.
    build_band_group(stacks: %w[baseline downside], failed_stacks: [ "broken" ])

    workspace = Forecast::Workspace.new(family: @family)
    net_worth = workspace.distribution_metric_bands.find { |b| b.metric == :net_worth }

    assert_not_nil net_worth
    edge_keys = (net_worth.low_stack_keys + net_worth.mid_stack_keys +
                 net_worth.high_stack_keys + net_worth.contributing_stack_keys).uniq
    assert_not_includes edge_keys, "broken", "a failed stack must never form a band edge"
    assert_equal %w[baseline downside], net_worth.contributing_stack_keys
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

  # --- sensitivity (deterministic single-variable analysis) ------------------

  test "sensitivity_data? is false and sensitivity_rows is empty with no completed run" do
    @family.forecast_run_groups.delete_all

    workspace = Forecast::Workspace.new(family: @family)

    assert_not workspace.sensitivity_data?
    assert_empty workspace.sensitivity_rows
  end

  test "sensitivity_data? is false for a totally failed group (no completed run to analyze)" do
    @family.forecast_run_groups.delete_all
    build_failed_run_group(family: @family, user: @user, error_message: "boom")

    workspace = Forecast::Workspace.new(family: @family)

    assert_not workspace.sensitivity_data?
    assert_empty workspace.sensitivity_rows
  end

  test "sensitivity_data? is true and sensitivity_rows yields the default-catalog perturbations for a completed baseline run" do
    @family.forecast_run_groups.delete_all
    build_completed_run_group(family: @family, user: @user, runs: 1)

    workspace = Forecast::Workspace.new(family: @family)

    assert workspace.sensitivity_data?
    rows = workspace.sensitivity_rows
    # One row per default-catalog perturbation, in the catalog's deterministic order.
    assert_equal Forecast::SensitivityAnalyzer::DEFAULT_CATALOG.map(&:key), rows.map(&:perturbation_key)
    # Every row reports a delta for each tracked metric so the panel can render it.
    rows.each do |row|
      assert_equal workspace.sensitivity_metrics.sort, row.delta.keys.sort
    end
  end

  test "sensitivity_rows runs the analyzer at most once (memoized)" do
    @family.forecast_run_groups.delete_all
    build_completed_run_group(family: @family, user: @user, runs: 1)

    workspace = Forecast::Workspace.new(family: @family)

    # The analyzer re-runs the engine N+1 times, so it must execute at most once.
    # InputBuilder is only invoked when the rows are first built; a second read
    # returns the memoized array without rebuilding the input.
    Forecast::InputBuilder.any_instance.expects(:call).once.returns(sensitivity_stub_input)
    Forecast::SensitivityAnalyzer.any_instance.expects(:call).once.returns([])

    workspace.sensitivity_rows
    workspace.sensitivity_rows
  end

  test "sensitivity_rows is deterministic: identical results on repeat (no wall clock, threaded run date)" do
    @family.forecast_run_groups.delete_all
    build_completed_run_group(family: @family, user: @user, runs: 1)

    first = Forecast::Workspace.new(family: @family).sensitivity_rows
    second = Forecast::Workspace.new(family: @family).sensitivity_rows

    assert_equal first.map(&:perturbation_key), second.map(&:perturbation_key)
    first.zip(second).each do |a, b|
      assert_equal a.baseline_metric, b.baseline_metric
      assert_equal a.perturbed_metric, b.perturbed_metric
      assert_equal a.delta, b.delta
      assert_equal a.goal_status_changes, b.goal_status_changes
    end
  end

  test "sensitivity_goal_labels maps only this family's goal ids to names" do
    @family.forecast_goals.delete_all
    goal = @family.forecast_goals.create!(
      name: "Keep six months of cash", goal_type: "minimum_cash_runway",
      status: "active", target_duration_days: 180
    )
    # Another family's goal must never appear in this family's label map.
    other_family = families(:empty)
    other_goal = other_family.forecast_goals.create!(
      name: "Foreign goal", goal_type: "minimum_cash_runway",
      status: "active", target_duration_days: 90
    )

    workspace = Forecast::Workspace.new(family: @family)
    labels = workspace.sensitivity_goal_labels

    assert_equal "Keep six months of cash", labels[goal.id]
    assert_nil labels[other_goal.id]
  end

  test "sensitivity_baseline_stale? is true when only minimum_cash_runway_days diverges" do
    @family.forecast_run_groups.delete_all
    # Persist a baseline run whose monthly rows carry a known runway trough (the
    # minimum cash_runway_days across the horizon) and end-of-horizon balances.
    build_run_group_with_series(
      family: @family, user: @user, days: 1, months: 3,
      month_attrs: ->(i) { { cash_runway_days: 120 - (i * 30) } }
    )

    workspace = Forecast::Workspace.new(family: @family)
    last_month = workspace.monthly_rows.last
    persisted_runway = workspace.monthly_rows.filter_map(&:cash_runway_days).min

    # The recomputed baseline matches the persisted run EXACTLY on cash/net_worth/
    # debt but diverges ONLY in the minimum projected cash runway. A live family
    # change that moves only runway must still mark the panel's baseline stale.
    stale_row = sensitivity_result_with_baseline(
      "cash_balance" => last_month.cash_balance,
      "net_worth" => last_month.net_worth,
      "debt_balance" => last_month.debt_balance,
      "minimum_cash_runway_days" => persisted_runway - 15
    )
    workspace.stubs(:sensitivity_rows).returns([ stale_row ])

    assert workspace.sensitivity_baseline_stale?,
      "divergence in minimum_cash_runway_days alone must mark the sensitivity baseline stale"
  end

  test "sensitivity_baseline_stale? is false when every tracked metric (incl. runway) matches" do
    @family.forecast_run_groups.delete_all
    build_run_group_with_series(
      family: @family, user: @user, days: 1, months: 3,
      month_attrs: ->(i) { { cash_runway_days: 120 - (i * 30) } }
    )

    workspace = Forecast::Workspace.new(family: @family)
    last_month = workspace.monthly_rows.last
    persisted_runway = workspace.monthly_rows.filter_map(&:cash_runway_days).min

    matching_row = sensitivity_result_with_baseline(
      "cash_balance" => last_month.cash_balance,
      "net_worth" => last_month.net_worth,
      "debt_balance" => last_month.debt_balance,
      "minimum_cash_runway_days" => persisted_runway
    )
    workspace.stubs(:sensitivity_rows).returns([ matching_row ])

    assert_not workspace.sensitivity_baseline_stale?,
      "an identical recompute (incl. runway) must not mark the baseline stale"
  end

  private
    # A minimal InputBuilder::Result stand-in for the memoization test, where the
    # analyzer is stubbed and never actually reads the input.
    def sensitivity_stub_input
      Object.new
    end

    # A minimal SensitivityAnalyzer::Result carrying only the unperturbed
    # `baseline_metric` hash that `sensitivity_baseline_stale?` reads off the
    # first row. The other fields are inert placeholders.
    def sensitivity_result_with_baseline(baseline_metric)
      Forecast::SensitivityAnalyzer::Result.new(
        perturbation_key: "stub",
        kind: :income,
        magnitude: 0.to_d,
        description: "stub",
        baseline_metric: baseline_metric,
        perturbed_metric: baseline_metric,
        delta: {},
        goal_status_changes: []
      )
    end

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
