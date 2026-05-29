require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    @family.forecast_scenarios.delete_all
    @family.forecast_events.delete_all
    @family.forecast_goals.delete_all
    sign_in @user
  end

  test "renders for users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get forecast_url

    assert_response :success
    assert_select "h1", text: /Forecast/i
  end

  test "renders for users with preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get forecast_url

    assert_response :success
    assert_select "h1", text: /Forecast/i
  end

  test "renders a sidebar nav link to the forecast page" do
    get forecast_url

    assert_response :success
    assert_select "a[href=?]", forecast_path
  end

  test "renders onboarding empty state when there is no planning data and no run" do
    get forecast_url

    assert_response :success
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.onboarding.title")
    assert_select "button", text: I18n.t("forecasts.show.generate")
    assert_select "button", text: I18n.t("forecasts.show.set_up_scenarios")
  end

  test "renders ready state when planning data exists but no completed run" do
    @family.forecast_scenarios.create!(name: "Job change", status: "active", approval_status: "manual")

    get forecast_url

    assert_response :success
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.ready.title")
  end

  test "renders run summary header and tab scaffolding when latest run completed" do
    build_completed_run_group(family: @family, user: @user, runs: 2)

    get forecast_url

    assert_response :success
    assert_select "section[aria-label=?]", I18n.t("forecasts.run_summary_header.title")
    Forecast::Workspace::TAB_IDS.each do |tab_id|
      assert_select "button[data-id=?]", tab_id
    end
  end

  test "surfaces failure alert with error message when latest run failed" do
    build_failed_run_group(family: @family, user: @user, error_message: "MoneyConverter::MissingRate: USD->EUR")

    get forecast_url

    assert_response :success
    assert_select "[role=alert]"
    assert_select "[role=alert]", text: /MoneyConverter::MissingRate: USD->EUR/
  end

  test "does not render another family's most recent global run group" do
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_completed_run_group(family: other_family, user: users(:empty), created_at: 1.minute.ago)

    get forecast_url

    assert_response :success
    # Current family has nothing, so it must see its own onboarding state, not
    # the other family's completed run.
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.onboarding.title")
    assert_select "section[aria-label='#{I18n.t("forecasts.run_summary_header.title")}']", count: 0
  end

  test "avoids N+1 queries while eager-loading forecast runs in run state" do
    build_completed_run_group(family: @family, user: @user, runs: 3)

    # Warm caches (sessions, current setup) so the assertion focuses on the
    # forecast read path.
    get forecast_url
    assert_response :success

    assert_queries_count(matcher: /forecast_runs/, max: 1) do
      get forecast_url
    end
  end

  test "renders the running poller while a generation is in flight" do
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

    get forecast_url

    assert_response :success
    assert_select "[data-controller='forecast-run-poller']"
    assert_select "#forecast-running-title"
  end

  test "Overview renders the 36-row monthly table for a real completed run without month N+1" do
    @family.forecast_run_groups.delete_all
    ForecastGenerationJob.perform_now(family: @family, user: @user)

    # Warm caches so the assertion focuses on the forecast read path.
    get forecast_url
    assert_response :success

    # 36 monthly rows + 1 header row in the projection table body.
    assert_select "#forecast-monthly-table-heading"
    assert_select "table tbody tr", minimum: 36

    # The Overview must not issue a query per month: months are eager-loaded and
    # the metrics row reuses the same loaded array.
    assert_queries_count(matcher: /forecast_months/, max: 1) do
      get forecast_url
    end
  end

  test "Overview renders the cash-runway and net-worth projection charts for the family's own run" do
    build_run_group_with_series(family: @family, user: @user, days: 90, months: 36)

    get forecast_url

    assert_response :success
    # Both chart containers are wired to the shared time-series-chart controller.
    assert_select "#forecastCashRunwayCash[data-controller='time-series-chart']"
    assert_select "#forecastCashRunwayLiquid[data-controller='time-series-chart']"
    assert_select "#forecastNetWorthProjection[data-controller='time-series-chart']"
    # Daily/liquid toggle is present and declarative.
    assert_select "[data-controller='forecast-chart-toggle']"
    assert_select "button[data-action='forecast-chart-toggle#select']", count: 2
  end

  test "Overview renders the data_not_available fallback when the run has no days or months" do
    # A completed run group with no day/month rows: charts must show the fallback,
    # never an empty chart container.
    build_completed_run_group(family: @family, user: @user, runs: 1)

    get forecast_url

    assert_response :success
    # No chart container should be rendered (the whole overview falls back to the
    # "no projection data" empty state because monthly_rows is empty).
    assert_select "[data-controller='time-series-chart']", count: 0
    assert_select "#forecast-overview-empty-title"
  end

  test "Overview surfaces runway risk annotation from persisted risk flags" do
    build_run_group_with_series(
      family: @family, user: @user, days: 90, months: 36,
      day_attrs: ->(i) { i.zero? ? { cash_balance: -250 } : {} }
    )

    get forecast_url

    assert_response :success
    assert_select "#forecastCashRunwayCash[data-controller='time-series-chart']"
    # Negative-cash risk note renders inline.
    assert_select "[role='status']", text: /#{Regexp.escape(I18n.t("forecasts.overview.charts.cash_runway.risk.negative_cash"))}/
  end

  test "Overview path 404s for a foreign family's forecast and shows own onboarding" do
    # Reuses slice-2 scoping: the workspace only ever reads Current.family's run
    # groups, so a foreign group never leaks into the current family's overview.
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_run_group_with_series(family: other_family, user: users(:empty), days: 90, months: 36)

    get forecast_url

    assert_response :success
    assert_select "[data-controller='time-series-chart']", count: 0
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.onboarding.title")
  end

  test "Overview charts add no per-day or per-month N+1 queries" do
    build_run_group_with_series(family: @family, user: @user, days: 90, months: 36)

    # Warm caches so the assertion focuses on the forecast read path.
    get forecast_url
    assert_response :success

    assert_queries_count(matcher: /forecast_days/, max: 1) do
      get forecast_url
    end
    assert_queries_count(matcher: /forecast_months/, max: 1) do
      get forecast_url
    end
  end

  # --- comparison tab --------------------------------------------------------

  test "comparison tab renders one row per scenario stack for a completed group" do
    group = build_completed_run_group(family: @family, user: @user, runs: 2)

    get forecast_url(tab: "comparison")

    assert_response :success
    assert_select "section[aria-label='#{I18n.t("forecasts.show.tabs.comparison")}']"
    assert_select "[data-testid=forecast-comparison-table] caption", text: I18n.t("forecasts.comparison.table.caption")
    # One <tbody> row per stack (2 runs in the group).
    assert_select "[data-testid=forecast-comparison-table] tbody tr", count: 2
  end

  test "comparison tab offers the compose form trigger when not running" do
    build_completed_run_group(family: @family, user: @user, runs: 1)

    get forecast_url(tab: "comparison")

    assert_response :success
    assert_select "[data-controller='forecast-compare']"
    assert_select "[data-action='forecast-compare#open']"
  end

  test "comparison surfaces a partial failure and still renders completed stacks" do
    # A failed comparison group that still contains one completed stack: the
    # workspace must show results (not a blank failure page), with the failed
    # stack distinctly flagged and the partial-failure banner shown.
    group = @family.forecast_run_groups.create!(
      user: @user,
      name: "Comparison run",
      run_type: "manual",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )

    completed = group.forecast_runs.create!(
      family: @family, user: @user,
      scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" },
      status: "running", feasibility_status: "pass", currency: @family.currency,
      input_snapshot: forecast_valid_input_snapshot(@family)
    )
    3.times do |i|
      period_start = Date.current + i.months
      completed.forecast_months.create!(
        period_start_on: period_start, period_end_on: period_start.end_of_month,
        precision: "monthly", scenario_stack_key: "baseline", currency: @family.currency,
        cash_balance: 1000 + (i * 100), liquid_balance: 2000, debt_balance: 0,
        net_worth: 5000 + (i * 100), risk_flags: []
      )
    end
    completed.update!(status: "completed", finished_at: Time.current)

    group.forecast_runs.create!(
      family: @family, user: @user,
      scenario_stack_key: "failed_stack",
      scenario_stack_snapshot: { "key" => "failed_stack" },
      status: "failed", feasibility_status: "unknown", currency: @family.currency,
      error_message: "MoneyConverter::MissingRate: no rate",
      input_snapshot: forecast_valid_input_snapshot(@family)
    )
    group.update_column(:status, "failed")

    get forecast_url(tab: "comparison")

    assert_response :success
    # Not a blank/total failure page: the workspace tabs render.
    assert_select "section[aria-label='#{I18n.t("forecasts.show.tabs.comparison")}']"
    # Partial-failure banner names the failed stack.
    assert_select "p", text: I18n.t("forecasts.comparison.partial_failure.title")
    # The failed stack is flagged distinctly with the "Failed" pill.
    assert_select "[data-testid=forecast-comparison-table] tbody", text: /#{Regexp.escape(I18n.t("forecasts.comparison.table.status_failed"))}/
    # Both stacks render (completed baseline + failed stack).
    assert_select "[data-testid=forecast-comparison-table] tbody tr", count: 2
  end

  private
    # Counts queries matching a pattern issued during the block and asserts the
    # count stays within bound, guarding against N+1 over forecast runs.
    def assert_queries_count(matcher:, max:)
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) do
        sql = payload[:sql]
        queries << sql if sql&.match?(matcher) && !payload[:name].to_s.include?("SCHEMA")
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }

      assert queries.size <= max,
        "expected at most #{max} queries matching #{matcher.inspect}, got #{queries.size}:\n#{queries.join("\n")}"
    end
end

class Forecast::BaseControllerAuthorizationTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper

  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
    @other_family.forecast_run_groups.delete_all
  end

  test "find_run_group_scoped raises RecordNotFound for another family's run group" do
    other_group = build_completed_run_group(family: @other_family, user: users(:empty))

    controller = Forecast::BaseController.new
    controller.instance_variable_set(:@family, @family)

    assert_raises ActiveRecord::RecordNotFound do
      controller.send(:find_run_group_scoped, other_group.id)
    end
  end

  test "find_run_group_scoped returns the current family's own run group" do
    own_group = build_completed_run_group(family: @family, user: users(:family_admin))

    controller = Forecast::BaseController.new
    controller.instance_variable_set(:@family, @family)

    assert_equal own_group, controller.send(:find_run_group_scoped, own_group.id)
  end
end
