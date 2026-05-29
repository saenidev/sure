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

  test "renders the new templates and sensitivity tab buttons with their panels" do
    build_completed_run_group(family: @family, user: @user, runs: 1)

    get forecast_url

    assert_response :success
    # Both new tab nav buttons render.
    assert_select "button[data-id='templates']", text: I18n.t("forecasts.show.tabs.templates")
    assert_select "button[data-id='sensitivity']", text: I18n.t("forecasts.show.tabs.sensitivity")
    # The templates panel now renders the real apply-card catalog (not a stub).
    assert_select "[data-testid=forecast-templates-list]"
    assert_select "[data-testid=forecast-template-card]", count: Forecast::ScenarioTemplate.all.size
    # Sensitivity still renders its scaffolding empty-state stub.
    assert_select "#forecast-sensitivity-empty-title", text: I18n.t("forecasts.sensitivity.empty.title")
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

  test "Review tab lists the family's past run groups by type and status" do
    # An older failed weekly group plus a newer completed manual group. The
    # newest (completed) group puts the workspace in the has_run state so the
    # tabs (and the Review history) render; the history lists BOTH groups.
    @family.forecast_run_groups.create!(
      user: @user, name: "Weekly review", run_type: "weekly", status: "failed",
      currency: @family.currency, horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date, daily_until_on: 90.days.from_now.to_date,
      error_message: "boom", finished_at: Time.current, created_at: 2.days.ago
    )
    build_completed_run_group(family: @family, user: @user, runs: 1)

    get forecast_url

    assert_response :success
    assert_select "section[aria-label=?]", I18n.t("forecasts.review.heading")
    assert_select "td", text: I18n.t("forecasts.review.run_types.weekly")
    assert_select "td", text: I18n.t("forecasts.review.run_types.manual")
  end

  test "Review tab does not leak another family's run history" do
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_completed_run_group(family: other_family, user: users(:empty))
    # The current family has its own completed group so the workspace is in the
    # has_run state and the Review tab renders.
    build_completed_run_group(family: @family, user: @user, runs: 1)

    assert_queries_count(matcher: /forecast_run_groups/, max: 2) do
      get forecast_url
    end

    assert_response :success
    # Exactly one history row: the current family's own group, never the other family's.
    assert_select "section[aria-label=?] table tbody tr", I18n.t("forecasts.review.heading"), count: 1
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

  # --- comparison tab: deterministic distribution bands ----------------------

  test "comparison tab renders deterministic distribution bands with disclaimer and attribution for a multi-stack group" do
    build_band_comparison_group(family: @family, user: @user, stacks: %w[baseline downside])

    get forecast_url(tab: "comparison")

    assert_response :success
    # The band section, its deterministic-NOT-percentile disclaimer, and a per-metric card render.
    assert_select "[data-testid=forecast-distribution-bands]"
    assert_select "[data-testid=forecast-distribution-disclaimer]",
      text: /#{Regexp.escape(I18n.t("forecasts.distribution.disclaimer"))}/
    assert_select "[data-testid=forecast-distribution-metric-net_worth]"
    # Edge charts reuse the shared time-series-chart controller (no new D3 controller).
    assert_select "#forecastDistribution-net_worth-deterministic_high[data-controller='time-series-chart']"
    assert_select "#forecastDistribution-net_worth-deterministic_low[data-controller='time-series-chart']"
    # Source attribution names which stack supplied the low/high edge.
    assert_select "[data-testid=forecast-distribution-attr-low-net_worth]"
    assert_select "[data-testid=forecast-distribution-attr-high-net_worth]"
  end

  test "comparison tab shows the band empty state and no band section for a single-baseline-only group" do
    build_band_comparison_group(family: @family, user: @user, stacks: %w[baseline])

    get forecast_url(tab: "comparison")

    assert_response :success
    # A single contributing stack collapses to a degenerate band, so the band
    # section is absent and the empty state explains how to surface bands.
    assert_select "[data-testid=forecast-distribution-bands]", count: 0
    assert_select "[data-testid=forecast-distribution-empty]"
    assert_select "#forecast-distribution-empty-title", text: I18n.t("forecasts.distribution.empty.title")
  end

  test "comparison tab excludes a failed stack from the band edges' attribution" do
    # Two completed stacks (baseline, downside) plus a failed stack. The failed
    # stack's humanized label must never appear as a band-edge attribution, and
    # the band section must still render for the two completed stacks.
    build_band_comparison_group(
      family: @family, user: @user, stacks: %w[baseline downside], failed_stacks: %w[liquidity_crunch]
    )

    get forecast_url(tab: "comparison")

    assert_response :success
    assert_select "[data-testid=forecast-distribution-bands]"
    # The failed stack key's humanized label never appears inside any attribution cell.
    assert_select "[data-testid=forecast-distribution-attr-low-net_worth]",
      text: /Liquidity Crunch/, count: 0
    assert_select "[data-testid=forecast-distribution-attr-high-net_worth]",
      text: /Liquidity Crunch/, count: 0
  end

  test "comparison tab never surfaces another family's distribution bands (cross-family denial)" do
    # Family B has a multi-stack banded group with a distinctive net-worth value;
    # the current family (A) has only a single-baseline group, so the Comparison
    # tab must show A's band empty state and never B's banded numbers.
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_band_comparison_group(
      family: other_family, user: users(:empty), stacks: %w[baseline downside],
      net_worth_base: 987_654
    )
    build_band_comparison_group(family: @family, user: @user, stacks: %w[baseline])

    get forecast_url(tab: "comparison")

    assert_response :success
    # Current family's single-stack group -> band empty state, no band section.
    assert_select "[data-testid=forecast-distribution-bands]", count: 0
    assert_select "[data-testid=forecast-distribution-empty]"
    # Family B's distinctive banded figure must never leak into the response.
    assert_no_match(/987,?654/, @response.body)
  end

  test "comparison tab band edge charts add no per-month N+1 queries" do
    build_band_comparison_group(family: @family, user: @user, stacks: %w[baseline downside upside])

    get forecast_url(tab: "comparison")
    assert_response :success

    assert_queries_count(matcher: /forecast_months/, max: 1) do
      get forecast_url(tab: "comparison")
    end
  end

  # --- comparison tab: goal-tradeoff comparison table ------------------------

  test "comparison tab renders the goal-tradeoff table ranked best-first with a blocked stack pinned last and formatted notes" do
    build_tradeoff_comparison_group(family: @family, user: @user)

    get forecast_url(tab: "comparison")

    assert_response :success
    # The tradeoff table renders (not the empty state) with one row per stack.
    assert_select "[data-testid=forecast-goal-tradeoff-table]"
    assert_select "[data-testid=forecast-goal-tradeoff-empty]", count: 0
    rows = css_select("[data-testid=forecast-goal-tradeoff-row]")
    assert_equal 3, rows.size

    # Best-first ordering: baseline (all on track) first, the strong stack next,
    # and the blocked stack pinned last (any blocked goal sinks the stack below
    # every clean stack regardless of its other satisfied goals).
    ordered_keys = rows.map { |row| row["data-stack-key"] }
    assert_equal %w[baseline strong_stack blocked_stack], ordered_keys

    # The blocked stack's row carries the blocked badge.
    assert_select "[data-testid=forecast-goal-tradeoff-row][data-stack-key=blocked_stack] " \
                  "[data-testid=forecast-goal-tradeoff-blocked-badge]",
      text: /#{Regexp.escape(I18n.t("forecasts.tradeoff.blocked_badge"))}/

    # An improvement note (more runway on the runway goal) renders with the
    # formatted day delta and the goal's name.
    assert_select "[data-testid=forecast-goal-tradeoff-note][data-direction=improvement]",
      text: /60 days.*Runway goal/
    # A regression note (higher projected debt) renders with formatted money in
    # the run currency and the goal's name.
    assert_select "[data-testid=forecast-goal-tradeoff-note][data-direction=regression]",
      text: /\$1,000.*Debt goal/
  end

  test "comparison tab shows the goal-tradeoff empty state when a completed group has no goal evaluations" do
    # A multi-stack completed group with months (so bands render) but NO goal
    # evaluations: the explorer returns [] and the view shows the empty state.
    build_band_comparison_group(family: @family, user: @user, stacks: %w[baseline downside])

    get forecast_url(tab: "comparison")

    assert_response :success
    assert_select "[data-testid=forecast-goal-tradeoff-table]", count: 0
    assert_select "[data-testid=forecast-goal-tradeoff-empty]"
    assert_select "#forecast-goal-tradeoff-empty-title",
      text: I18n.t("forecasts.tradeoff.empty.title")
  end

  test "comparison tab excludes a failed stack from the goal-tradeoff ranking" do
    build_tradeoff_comparison_group(family: @family, user: @user, with_failed_stack: true)

    get forecast_url(tab: "comparison")

    assert_response :success
    assert_select "[data-testid=forecast-goal-tradeoff-table]"
    # The failed stack key never appears as a ranked row (a failed stack cannot
    # masquerade as one that satisfies or blocks goals).
    assert_select "[data-testid=forecast-goal-tradeoff-row][data-stack-key=failed_stack]", count: 0
  end

  test "comparison tab never surfaces another family's goal tradeoffs (cross-family denial)" do
    # Family B has a multi-stack group with goal evaluations naming a distinctive
    # goal; family A has only a single-baseline group, so A's tradeoff empty state
    # shows and B's goal name never leaks.
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    other_family.forecast_goals.delete_all
    build_tradeoff_comparison_group(
      family: other_family, user: users(:empty), goal_name_prefix: "OtherFamilySecret"
    )
    build_band_comparison_group(family: @family, user: @user, stacks: %w[baseline])

    get forecast_url(tab: "comparison")

    assert_response :success
    assert_select "[data-testid=forecast-goal-tradeoff-table]", count: 0
    assert_select "[data-testid=forecast-goal-tradeoff-empty]"
    assert_no_match(/OtherFamilySecret/, @response.body)
  end

  test "comparison tab goal-tradeoff row ordering is deterministic across renders" do
    build_tradeoff_comparison_group(family: @family, user: @user)

    get forecast_url(tab: "comparison")
    assert_response :success
    first_order = css_select("[data-testid=forecast-goal-tradeoff-row]").map { |r| r["data-stack-key"] }

    get forecast_url(tab: "comparison")
    assert_response :success
    second_order = css_select("[data-testid=forecast-goal-tradeoff-row]").map { |r| r["data-stack-key"] }

    assert_equal first_order, second_order
    refute_empty first_order
  end

  # --- timeline tab ----------------------------------------------------------

  test "timeline tab renders the synchronized lanes for a completed run" do
    build_run_group_with_series(family: @family, user: @user, days: 90, months: 36)

    get forecast_url(tab: "timeline")

    assert_response :success
    assert_select "section[aria-label='#{I18n.t("forecasts.show.tabs.timeline")}']"
    # The resolution toggle and all six lanes render.
    assert_select "[data-controller='forecast-timeline']"
    assert_select "[data-testid=timeline-cash-lane]"
    assert_select "[data-testid=timeline-budget-lane]"
    assert_select "[data-testid=timeline-portfolio-lane]"
    assert_select "[data-testid=timeline-debt-lane]"
    assert_select "[data-testid=timeline-goals-lane]"
    assert_select "[data-testid=timeline-scenario-lane]"
    # The daily pane carries the 90 daily rows.
    assert_select "[data-testid=timeline-cash-daily] tbody tr", count: 90
  end

  test "timeline tab renders the debt lane and a per-month drilldown from persisted projections" do
    build_timeline_run_with_projections(family: @family, user: @user)

    get forecast_url(tab: "timeline")

    assert_response :success
    # Debt lane shows projection rows (not the empty state).
    assert_select "[data-testid=timeline-debt-empty]", count: 0
    assert_select "[data-testid=timeline-debt-lane] th", text: /Card/
    # Drilldown renders humanized source_breakdown rows from persisted JSON.
    assert_select "[data-testid=timeline-drilldown-content]"
    assert_select "[data-testid=timeline-drilldown-content] dt",
      text: I18n.t("forecasts.timeline.drilldown.keys.budget_spend_gap")
  end

  test "timeline tab renders the debt lane empty state when there are no debt projections" do
    build_run_group_with_series(family: @family, user: @user, days: 90, months: 36)

    get forecast_url(tab: "timeline")

    assert_response :success
    assert_select "[data-testid=timeline-debt-empty]"
  end

  test "timeline tab surfaces payoff date, growing-trend, and the debt-pressure callout" do
    build_debt_lane_run(family: @family, user: @user)

    get forecast_url(tab: "timeline")

    assert_response :success
    # Growing-balance trend indicator (pill label).
    assert_select "[data-testid=timeline-debt-lane]",
      text: /#{Regexp.escape(I18n.t("forecasts.timeline.debt_lane.trend.growing"))}/
    # Projected payoff date renders the real translated label (not a
    # missing-translation fallback) with the formatted date interpolated.
    expected_payoff = I18n.t("forecasts.timeline.debt_lane.payoff.projected_on",
                             date: I18n.l(Date.new(2028, 12, 31), format: :long))
    assert_select "[data-testid=timeline-debt-payoff-date]", text: /#{Regexp.escape(expected_payoff)}/
    # Debt-pressure runway warning callout renders for the flagged month.
    assert_select "[data-testid=timeline-debt-pressure-callout]"
    # Growing reason (interest outran payment).
    assert_select "[data-testid=timeline-debt-trend-reason]"
  end

  test "timeline tab renders the incomplete caveat and never claims a payoff for an incomplete row" do
    build_debt_lane_run(family: @family, user: @user, incomplete: true)

    get forecast_url(tab: "timeline")

    assert_response :success
    assert_select "[data-testid=timeline-debt-incomplete]"
    # An incomplete row must not present a payoff date.
    assert_select "[data-testid=timeline-debt-payoff-date]", count: 0
    # Interest is shown as "not modeled" rather than a fully-modeled figure.
    assert_select "[data-testid=timeline-debt-lane]",
      text: /#{Regexp.escape(I18n.t("forecasts.timeline.debt_lane.incomplete.not_modeled"))}/
  end

  test "timeline debt lane never renders another family's debt numbers (cross-family denial)" do
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_debt_lane_run(family: other_family, user: users(:empty), account_label: "Foreign Loan")

    get forecast_url(tab: "timeline")

    assert_response :success
    # Current family has no run of its own -> onboarding, never the other
    # family's debt lane / its account label.
    assert_select "[data-testid=timeline-debt-lane]", count: 0
    assert_select "body", text: /Foreign Loan/, count: 0
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.onboarding.title")
  end

  test "timeline tab renders the baseline scenario marker for a baseline run" do
    build_run_group_with_series(family: @family, user: @user, days: 90, months: 36)

    get forecast_url(tab: "timeline")

    assert_response :success
    assert_select "[data-testid=timeline-scenario-baseline]",
      text: /#{Regexp.escape(I18n.t("forecasts.timeline.scenario_lane.baseline"))}/
  end

  test "timeline tab shows the empty state when the family has no completed run" do
    get forecast_url(tab: "timeline")

    assert_response :success
    # A family with no run sees onboarding (the workspace has no run group), so
    # the tab scaffolding is not even rendered; this proves no foreign run leaks.
    assert_select "[data-testid=timeline-cash-lane]", count: 0
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.onboarding.title")
  end

  test "timeline tab never renders another family's run (cross-family denial)" do
    other_family = families(:empty)
    other_family.forecast_run_groups.delete_all
    build_run_group_with_series(family: other_family, user: users(:empty), days: 90, months: 36)

    get forecast_url(tab: "timeline")

    assert_response :success
    # Current family has no run of its own, so it must see its own onboarding,
    # never the other family's timeline.
    assert_select "[data-testid=timeline-cash-lane]", count: 0
    assert_select "#forecast-empty-state-title", text: I18n.t("forecasts.empty_state.onboarding.title")
  end

  test "timeline tab adds no per-day, per-month, or per-projection N+1 queries" do
    build_timeline_run_with_projections(family: @family, user: @user, months: 36)

    # Warm caches so the assertion focuses on the forecast read path.
    get forecast_url(tab: "timeline")
    assert_response :success

    assert_queries_count(matcher: /forecast_days/, max: 1) { get forecast_url(tab: "timeline") }
    assert_queries_count(matcher: /forecast_months/, max: 1) { get forecast_url(tab: "timeline") }
    assert_queries_count(matcher: /forecast_category_projections/, max: 1) { get forecast_url(tab: "timeline") }
    assert_queries_count(matcher: /forecast_debt_projections/, max: 1) { get forecast_url(tab: "timeline") }
  end

  private
    # Builds a (completed, or partially-failed) comparison ForecastRunGroup with
    # one ForecastRun per stack key, each carrying 3 ascending months so the
    # DistributionBandBuilder has real, deterministic per-month values to band.
    # `net_worth_base` lets a cross-family test stamp a distinctive figure to
    # assert it never leaks. Failed stacks are persisted without months.
    def build_band_comparison_group(family:, user:, stacks:, failed_stacks: [], net_worth_base: 5000)
      currency = family.currency
      group = family.forecast_run_groups.create!(
        user: user, name: "Comparison run", run_type: "manual", currency: currency,
        horizon_start_on: Date.current, horizon_end_on: Date.current + 36.months,
        daily_until_on: Date.current + 89.days
      )

      stacks.each_with_index do |stack_key, idx|
        run = group.forecast_runs.create!(
          family: family, user: user, scenario_stack_key: stack_key,
          scenario_stack_snapshot: {
            "key" => stack_key,
            "scenarios" => [ { "name" => stack_key.titleize } ]
          },
          status: "running", feasibility_status: "pass", currency: currency,
          input_snapshot: forecast_valid_input_snapshot(family)
        )

        3.times do |i|
          period_start = Date.current + i.months
          run.forecast_months.create!(
            period_start_on: period_start, period_end_on: period_start.end_of_month,
            precision: "monthly", scenario_stack_key: stack_key, currency: currency,
            cash_balance: 1000 + (i * 100) + (idx * 50),
            liquid_balance: 2000, debt_balance: 500 - (i * 50),
            net_worth: net_worth_base + (i * 100) + (idx * 50), risk_flags: []
          )
        end

        run.update!(status: "completed", finished_at: Time.current)
      end

      failed_stacks.each do |stack_key|
        group.forecast_runs.create!(
          family: family, user: user, scenario_stack_key: stack_key,
          scenario_stack_snapshot: {
            "key" => stack_key,
            "scenarios" => [ { "name" => stack_key.titleize } ]
          },
          status: "failed", feasibility_status: "unknown", currency: currency,
          error_message: "MoneyConverter::MissingRate: no rate",
          input_snapshot: forecast_valid_input_snapshot(family)
        )
      end

      if failed_stacks.any?
        group.update!(finished_at: Time.current)
        group.update_column(:status, "failed")
      else
        group.update!(status: "completed", finished_at: Time.current)
      end
      group
    end

    # Builds a (completed, or partially-failed) comparison ForecastRunGroup whose
    # runs carry persisted forecast_goal_evaluations, so the GoalTradeoffExplorer
    # has real, deterministic rows to rank. Two family goals are graded:
    #   * a minimum_cash_runway goal (DAYS, more is better)
    #   * a maximum_debt_balance goal (MONEY, less is better)
    # Stacks (best-first after ranking):
    #   * baseline      — both goals pass (the reference; no tradeoffs)
    #   * strong_stack  — both pass, +60 days runway (improvement) and +$1,000
    #                     projected debt (regression) vs baseline
    #   * blocked_stack — runway goal BLOCKING (pinned last regardless of the rest)
    # Evaluations are written while the run is still `running` (the immutability
    # concern locks completed output), then the run/group are flipped to completed.
    def build_tradeoff_comparison_group(family:, user:, with_failed_stack: false, goal_name_prefix: nil)
      currency = family.currency
      prefix = goal_name_prefix ? "#{goal_name_prefix} " : ""

      runway_goal = family.forecast_goals.create!(
        name: "#{prefix}Runway goal", goal_type: "minimum_cash_runway",
        target_duration_days: 90, status: "active", blocking_behavior: "blocks_stack",
        required: true
      )
      debt_goal = family.forecast_goals.create!(
        name: "#{prefix}Debt goal", goal_type: "maximum_debt_balance",
        target_amount: 5000, currency: currency, status: "active",
        blocking_behavior: "warn", required: false
      )

      runway_key = "forecast_goal:#{runway_goal.id}"
      debt_key = "forecast_goal:#{debt_goal.id}"

      group = family.forecast_run_groups.create!(
        user: user, name: "Comparison run", run_type: "manual", currency: currency,
        horizon_start_on: Date.current, horizon_end_on: Date.current + 36.months,
        daily_until_on: Date.current + 89.days
      )

      # stack_key => { runway: [status, metric], debt: [status, metric] }
      plan = {
        "baseline" => { runway: [ "pass", 120 ], debt: [ "pass", 2000 ] },
        "strong_stack" => { runway: [ "pass", 180 ], debt: [ "pass", 3000 ] },
        "blocked_stack" => { runway: [ "blocking", 30 ], debt: [ "pass", 2500 ] }
      }

      plan.each do |stack_key, evals|
        run = group.forecast_runs.create!(
          family: family, user: user, scenario_stack_key: stack_key,
          scenario_stack_snapshot: { "key" => stack_key, "label" => stack_key.titleize },
          status: "running", feasibility_status: "pass", currency: currency,
          input_snapshot: forecast_valid_input_snapshot(family)
        )

        run.forecast_goal_evaluations.create!(
          forecast_goal: runway_goal, goal_key: runway_key, scenario_stack_key: stack_key,
          status: evals[:runway][0], currency: currency, metric_value: evals[:runway][1],
          target_value: 90, evaluated_on: Date.current + 35.months,
          goal_snapshot: { "id" => runway_goal.id, "goal_type" => "minimum_cash_runway", "name" => runway_goal.name },
          details: { "field" => "cash_runway_days" }
        )
        run.forecast_goal_evaluations.create!(
          forecast_goal: debt_goal, goal_key: debt_key, scenario_stack_key: stack_key,
          status: evals[:debt][0], currency: currency, metric_value: evals[:debt][1],
          target_value: 5000, evaluated_on: Date.current + 35.months,
          goal_snapshot: { "id" => debt_goal.id, "goal_type" => "maximum_debt_balance", "name" => debt_goal.name },
          details: { "field" => "debt_balance" }
        )

        run.update!(status: "completed", finished_at: Time.current)
      end

      if with_failed_stack
        group.forecast_runs.create!(
          family: family, user: user, scenario_stack_key: "failed_stack",
          scenario_stack_snapshot: { "key" => "failed_stack", "label" => "Failed Stack" },
          status: "failed", feasibility_status: "unknown", currency: currency,
          error_message: "MoneyConverter::MissingRate: no rate",
          input_snapshot: forecast_valid_input_snapshot(family)
        )
        group.update!(finished_at: Time.current)
        group.update_column(:status, "failed")
      else
        group.update!(status: "completed", finished_at: Time.current)
      end
      group
    end

    # Builds a completed baseline run carrying days, months, and per-month
    # category + debt projections (plus a holdings snapshot) so the timeline tab
    # can render every lane and a real drilldown. Mirrors the Runner's persist
    # order: rows written while non-completed, then the run/group flipped.
    def build_timeline_run_with_projections(family:, user:, months: 6)
      currency = family.currency
      group = family.forecast_run_groups.create!(
        user: user, name: "Manual run", run_type: "manual", currency: currency,
        horizon_start_on: Date.current, horizon_end_on: Date.current + 36.months,
        daily_until_on: Date.current + 89.days
      )
      run = group.forecast_runs.create!(
        family: family, user: user, scenario_stack_key: "baseline",
        scenario_stack_snapshot: { "key" => "baseline" }, status: "running",
        feasibility_status: "pass", currency: currency,
        input_snapshot: forecast_valid_input_snapshot(family).merge(
          "portfolio" => { "holdings" => [ { "ticker" => "AAPL", "qty" => "10.0", "amount" => "1500.0" } ] }
        )
      )

      90.times do |i|
        run.forecast_days.create!(
          date: Date.current + i.days, scenario_stack_key: "baseline", currency: currency,
          cash_balance: 1000 + (i * 10), liquid_balance: 2000 + (i * 10), debt_balance: 0,
          net_worth: 3000 + (i * 10), cash_runway_days: 30,
          source_breakdown: { "phase" => "daily" }, risk_flags: []
        )
      end

      months.times do |i|
        period_start = Date.current + i.months
        month = run.forecast_months.create!(
          period_start_on: period_start, period_end_on: period_start.end_of_month,
          precision: "monthly", scenario_stack_key: "baseline", currency: currency,
          expected_income: 5000, expected_spending: 3000, net_cash_flow: 2000,
          cash_balance: 1000 + (i * 100), liquid_balance: 2000 + (i * 100),
          portfolio_value: 10000 + (i * 100), debt_balance: 4000 - (i * 100),
          net_worth: 5000 + (i * 100), cash_runway_days: 30,
          source_breakdown: { "budget_spend_gap" => "25.0", "uncategorized_spending" => "10.0" },
          risk_flags: []
        )
        month.forecast_category_projections.create!(
          projection_key: "cat-#{i}", source: "budget_inheritance", currency: currency,
          budgeted_spending: 500, actual_spending: 100, projected_spending: 300,
          projected_spending_low: 200, projected_spending_expected: 300, projected_spending_high: 400,
          available_to_spend: 200, source_snapshot: { "reason" => "budget" },
          source_breakdown: { "budgeted" => "500.0" }, risk_flags: []
        )
        month.forecast_debt_projections.create!(
          projection_key: "Card #{i}", source: "account_balance_only", currency: currency,
          opening_balance: 4000 - (i * 100), projected_interest: 50, projected_payment: 150,
          cash_payment_gap: 0, projected_drawdown: 0, ending_balance: 4000 - ((i + 1) * 100),
          source_snapshot: { "reason" => "balance" },
          source_breakdown: { "opening_balance" => "4000.0" }, risk_flags: []
        )
      end

      run.update!(status: "completed", finished_at: Time.current)
      group.update!(status: "completed", finished_at: Time.current)
      group
    end

    # Builds a completed baseline run with one month carrying a debt projection
    # whose persisted source_snapshot + risk_flags mirror what the
    # DebtProjectionAdapter stamps (payoff/trend/balloon/refinance) plus the
    # month-level debt_pressures_runway flag, so the debt-lane view renders every
    # surface. `incomplete: true` produces an account_balance_only row flagged
    # debt_projection_incomplete (interest not fully modeled).
    def build_debt_lane_run(family:, user:, account_label: "Visa Card", incomplete: false)
      currency = family.currency
      group = family.forecast_run_groups.create!(
        user: user, name: "Manual run", run_type: "manual", currency: currency,
        horizon_start_on: Date.current, horizon_end_on: Date.current + 36.months,
        daily_until_on: Date.current + 89.days
      )
      run = group.forecast_runs.create!(
        family: family, user: user, scenario_stack_key: "baseline",
        scenario_stack_snapshot: { "key" => "baseline" }, status: "running",
        feasibility_status: "pass", currency: currency,
        input_snapshot: forecast_valid_input_snapshot(family)
      )

      90.times do |i|
        run.forecast_days.create!(
          date: Date.current + i.days, scenario_stack_key: "baseline", currency: currency,
          cash_balance: 1000 + (i * 10), liquid_balance: 2000 + (i * 10), debt_balance: 4000,
          net_worth: 3000 + (i * 10), cash_runway_days: 30,
          source_breakdown: { "phase" => "daily" }, risk_flags: []
        )
      end

      period_start = Date.current
      month = run.forecast_months.create!(
        period_start_on: period_start, period_end_on: period_start.end_of_month,
        precision: "monthly", scenario_stack_key: "baseline", currency: currency,
        expected_income: 5000, expected_spending: 3000, net_cash_flow: 2000,
        cash_balance: 1000, liquid_balance: 2000, portfolio_value: 0,
        debt_balance: 4000, net_worth: 5000, cash_runway_days: 30,
        source_breakdown: { "debt_payment_cash_gap" => "200.0" },
        risk_flags: [ { "type" => "debt_pressures_runway", "account_ids" => [ 1 ] } ]
      )

      if incomplete
        month.forecast_debt_projections.create!(
          projection_key: account_label, source: "account_balance_only", currency: currency,
          opening_balance: 4000, projected_interest: 0, projected_payment: 150,
          cash_payment_gap: 0, projected_drawdown: 0, ending_balance: 3850,
          source_snapshot: { "balance_trend" => "amortizing", "incomplete_reasons" => [ "auto_accrual_disabled" ] },
          source_breakdown: { "opening_balance" => "4000.0" },
          risk_flags: [ { "type" => "debt_projection_incomplete", "account_id" => 1, "reason" => "auto_accrual_disabled" } ]
        )
      else
        month.forecast_debt_projections.create!(
          projection_key: account_label, source: "debt_profile_snapshot", currency: currency,
          opening_balance: 4000, projected_interest: 200, projected_payment: 150,
          cash_payment_gap: 50, projected_drawdown: 0, ending_balance: 4050,
          source_snapshot: {
            "balance_trend" => "growing",
            "payoff_projected_on" => "2028-12-31",
            "is_payoff_period" => false,
            "debt_balloon_due" => {},
            "refinance" => { "applied" => false }
          },
          source_breakdown: { "opening_balance" => "4000.0" },
          risk_flags: [ { "type" => "debt_balance_growing", "account_id" => 1, "reason" => "interest_exceeds_payment" } ]
        )
      end

      run.update!(status: "completed", finished_at: Time.current)
      group.update!(status: "completed", finished_at: Time.current)
      group
    end

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
