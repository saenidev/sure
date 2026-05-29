require "test_helper"

class Forecast::ComparisonSeriesBuilderTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
  end

  # Builds a non-completed run carrying `months` ForecastMonth rows so the
  # builder has a multi-point series to read. Mirrors how the Runner persists
  # output (rows written while the run is non-completed, then flipped). The run
  # is returned still in `running` status so the caller can flip the group.
  def build_run(group, stack_key:, months: 36, net_worth_base: 5000, snapshot: nil, status: "completed")
    run = group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: stack_key,
      scenario_stack_snapshot: snapshot || { "key" => stack_key },
      status: "running",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: forecast_valid_input_snapshot(@family)
    )

    months.times do |i|
      period_start = Date.current + i.months
      run.forecast_months.create!(
        period_start_on: period_start,
        period_end_on: period_start.end_of_month,
        precision: "monthly",
        scenario_stack_key: stack_key,
        currency: @family.currency,
        cash_balance: 1000 + (i * 100),
        liquid_balance: 2000 + (i * 100),
        debt_balance: 500,
        net_worth: net_worth_base + (i * 100),
        risk_flags: []
      )
    end

    run.update!(status: status == "completed" ? "completed" : "running", feasibility_status: "pass", finished_at: Time.current)
    run
  end

  def new_group
    @family.forecast_run_groups.create!(
      user: @user,
      name: "Comparison run",
      run_type: "manual",
      currency: @family.currency,
      horizon_start_on: Date.current,
      horizon_end_on: 36.months.from_now.to_date,
      daily_until_on: 90.days.from_now.to_date
    )
  end

  # --- one series per scenario stack key, ordered stably ---------------------

  test "builds one series per scenario stack key, baseline first then by key" do
    group = new_group
    build_run(group, stack_key: "zzz_stack", net_worth_base: 9000)
    build_run(group, stack_key: "aaa_stack", net_worth_base: 7000)
    build_run(group, stack_key: "baseline", net_worth_base: 5000)
    group.update!(status: "completed", finished_at: Time.current)

    builder = Forecast::ComparisonSeriesBuilder.new(runs: group.forecast_runs.includes(:forecast_months))
    stacks = builder.stacks

    assert_equal 3, stacks.size
    assert_equal %w[baseline aaa_stack zzz_stack], stacks.map(&:key),
      "baseline must lead, then remaining stacks ordered by key"
    stacks.each do |stack|
      assert_equal 36, stack.net_worth_series.values.size
    end
  end

  test "a group with a single baseline run still produces one series" do
    group = new_group
    build_run(group, stack_key: "baseline", net_worth_base: 5000)
    group.update!(status: "completed", finished_at: Time.current)

    builder = Forecast::ComparisonSeriesBuilder.new(runs: group.forecast_runs.includes(:forecast_months))
    stacks = builder.stacks

    assert_equal 1, stacks.size
    assert_equal "baseline", stacks.first.key
    assert stacks.first.net_worth_series.any?
  end

  # --- end-of-horizon metrics + labels ---------------------------------------

  test "exposes end-of-horizon cash, net worth, and debt money for each stack" do
    group = new_group
    build_run(group, stack_key: "baseline", net_worth_base: 5000)
    group.update!(status: "completed", finished_at: Time.current)

    stack = Forecast::ComparisonSeriesBuilder.new(runs: group.forecast_runs.includes(:forecast_months)).stacks.first

    # Last of 36 months (i = 35): cash 1000 + 3500, net worth 5000 + 3500, debt 500.
    assert_equal Money.new(4500, @family.currency), stack.end_cash
    assert_equal Money.new(8500, @family.currency), stack.end_net_worth
    assert_equal Money.new(500, @family.currency), stack.end_debt
  end

  test "labels a non-baseline stack from its scenario snapshot names" do
    group = new_group
    snapshot = { "key" => "abc", "scenarios" => [ { "name" => "New job" }, { "name" => "Move" } ] }
    build_run(group, stack_key: "abc", snapshot: snapshot)
    group.update!(status: "completed", finished_at: Time.current)

    stack = Forecast::ComparisonSeriesBuilder.new(runs: group.forecast_runs.includes(:forecast_months)).stacks
      .find { |s| s.key == "abc" }

    assert_equal "New job + Move", stack.label
  end

  # --- partial failure: failed stack surfaced, completed stacks still built ---

  test "a failed run still yields a stack flagged as failed while others build" do
    group = new_group
    build_run(group, stack_key: "baseline", net_worth_base: 5000)
    # A failed run: persist it failed with no months (mirrors a stack that
    # errored mid-group). Group stays non-completed so this run is allowed.
    failed = group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: "failed_stack",
      scenario_stack_snapshot: { "key" => "failed_stack" },
      status: "failed",
      feasibility_status: "unknown",
      currency: @family.currency,
      error_message: "MoneyConverter::MissingRate: no rate",
      input_snapshot: forecast_valid_input_snapshot(@family)
    )

    builder = Forecast::ComparisonSeriesBuilder.new(runs: group.forecast_runs.includes(:forecast_months))
    stacks = builder.stacks

    failed_stack = stacks.find { |s| s.key == "failed_stack" }
    completed_stack = stacks.find { |s| s.key == "baseline" }

    assert failed_stack.failed, "failed run must surface as a failed stack"
    assert_nil failed_stack.net_worth_series, "failed stack has no series"
    assert_not completed_stack.failed
    assert completed_stack.net_worth_series.any?, "completed stack still builds its series"
  end

  # --- no recompute: reads persisted rows only -------------------------------

  test "never invokes the engine (reads persisted runs only)" do
    group = new_group
    build_run(group, stack_key: "baseline", net_worth_base: 5000)
    group.update!(status: "completed", finished_at: Time.current)

    Forecast::Engine.any_instance.expects(:call).never

    Forecast::ComparisonSeriesBuilder.new(runs: group.forecast_runs.includes(:forecast_months)).stacks.each do |stack|
      stack.net_worth_series
    end
  end
end
