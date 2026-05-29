require "test_helper"

class Forecast::SeriesBuilderTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
  end

  def baseline_run_for(group)
    group.forecast_runs.find { |r| r.scenario_stack_key == "baseline" } || group.forecast_runs.first
  end

  # --- happy path: shape, ordering, currency, correct columns -----------------

  test "produces 90 chronologically ordered daily points for the cash runway" do
    group = build_run_group_with_series(family: @family, user: @user, days: 90, months: 36)
    builder = Forecast::SeriesBuilder.new(baseline_run_for(group))

    series = builder.cash_runway_series

    assert_equal 90, series.values.size
    dates = series.values.map(&:date)
    assert_equal dates.sort, dates, "daily points must be chronologically ordered"
  end

  test "produces 36 chronologically ordered monthly points for net worth" do
    group = build_run_group_with_series(family: @family, user: @user, days: 90, months: 36)
    builder = Forecast::SeriesBuilder.new(baseline_run_for(group))

    series = builder.net_worth_series

    assert_equal 36, series.values.size
    dates = series.values.map(&:date)
    assert_equal dates.sort, dates, "monthly points must be chronologically ordered"
  end

  test "net worth series reads ForecastMonth#net_worth not cash_balance" do
    group = build_run_group_with_series(
      family: @family, user: @user, days: 2, months: 3,
      month_attrs: ->(i) { { cash_balance: 1, net_worth: 9000 + i } }
    )
    run = baseline_run_for(group)
    builder = Forecast::SeriesBuilder.new(run)

    values = builder.net_worth_series.values.map { |v| v.value.amount.to_i }

    assert_equal run.forecast_months.order(:period_start_on).map { |m| m.net_worth.to_i }, values
    assert_not_includes values, 1, "must not serialize cash_balance for the net-worth line"
  end

  test "values are wrapped as Money in the run currency" do
    group = build_run_group_with_series(family: @family, user: @user, days: 2, months: 2)
    run = baseline_run_for(group)
    builder = Forecast::SeriesBuilder.new(run)

    first = builder.cash_runway_series.values.first
    assert_instance_of Money, first.value
    assert_equal run.currency, first.value.currency.iso_code
  end

  test "liquid runway series reads ForecastDay#liquid_balance" do
    group = build_run_group_with_series(
      family: @family, user: @user, days: 3, months: 2,
      day_attrs: ->(i) { { cash_balance: 1, liquid_balance: 7000 + i } }
    )
    run = baseline_run_for(group)
    builder = Forecast::SeriesBuilder.new(run)

    values = builder.liquid_runway_series.values.map { |v| v.value.amount.to_i }
    assert_equal run.forecast_days.order(:date).map { |d| d.liquid_balance.to_i }, values
  end

  # --- empty/edge: fewer than two rows yields a nil (non-present) series -------

  test "a run with zero days/months yields nil series so the view falls back" do
    group = build_run_group_with_series(family: @family, user: @user, days: 0, months: 0)
    builder = Forecast::SeriesBuilder.new(baseline_run_for(group))

    assert_nil builder.cash_runway_series
    assert_nil builder.liquid_runway_series
    assert_nil builder.net_worth_series
  end

  test "a run with a single day/month yields nil series (Series needs >= 2 points)" do
    group = build_run_group_with_series(family: @family, user: @user, days: 1, months: 1)
    builder = Forecast::SeriesBuilder.new(baseline_run_for(group))

    assert_nil builder.cash_runway_series
    assert_nil builder.net_worth_series
  end

  # --- negative cash / risk annotation read from persisted risk_flags ---------

  test "negative cash_balance days still serialize without crashing" do
    group = build_run_group_with_series(
      family: @family, user: @user, days: 5, months: 2,
      day_attrs: ->(i) { { cash_balance: i.zero? ? -500 : 1000 } }
    )
    builder = Forecast::SeriesBuilder.new(baseline_run_for(group))

    series = builder.cash_runway_series
    assert_equal 5, series.values.size
    assert builder.negative_cash?
    assert builder.runway_risk?
  end

  test "runway risk flag types are read from persisted ForecastDay risk_flags" do
    group = build_run_group_with_series(
      family: @family, user: @user, days: 4, months: 2,
      day_attrs: ->(i) { i == 2 ? { risk_flags: [ { "type" => "cash_shortfall" } ] } : {} }
    )
    builder = Forecast::SeriesBuilder.new(baseline_run_for(group))

    assert_equal [ "cash_shortfall" ], builder.runway_risk_flag_types
    assert builder.runway_risk?
  end

  test "no risk when balances are positive and no flags persisted" do
    group = build_run_group_with_series(family: @family, user: @user, days: 3, months: 2)
    builder = Forecast::SeriesBuilder.new(baseline_run_for(group))

    assert_not builder.negative_cash?
    assert_equal [], builder.runway_risk_flag_types
    assert_not builder.runway_risk?
  end

  # --- no-recompute: builder never instantiates the engine --------------------

  test "builder never instantiates Forecast::Engine (reads persisted rows only)" do
    group = build_run_group_with_series(family: @family, user: @user, days: 3, months: 3)
    run = baseline_run_for(group)

    Forecast::Engine.any_instance.expects(:call).never
    Forecast::Engine.expects(:new).never

    builder = Forecast::SeriesBuilder.new(run)
    builder.cash_runway_series
    builder.liquid_runway_series
    builder.net_worth_series
    builder.runway_risk?
  end

  # --- performance: pre-loaded rows add no queries ----------------------------

  test "reuses pre-loaded day/month arrays without issuing queries" do
    group = build_run_group_with_series(family: @family, user: @user, days: 3, months: 3)
    run = baseline_run_for(group)
    days = run.forecast_days.order(:date).to_a
    months = run.forecast_months.order(:period_start_on).to_a

    builder = Forecast::SeriesBuilder.new(run, days: days, months: months)

    assert_no_queries do
      builder.cash_runway_series
      builder.net_worth_series
      builder.runway_risk?
    end
  end
end
