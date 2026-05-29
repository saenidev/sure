require "test_helper"

class Forecast::DistributionBandBuilderTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
  end

  # Builds a (by default completed) run carrying `net_worth_by_month`-driven
  # ForecastMonth rows so the builder has deterministic per-month values to band.
  # Rows are written while the run is non-completed (immutability only locks
  # completed output) then flipped, mirroring how the Runner persists output.
  # `values` is an array of hashes keyed by metric (net_worth/cash_balance/
  # debt_balance); month i reads values[i]. Months start at `start_on`.
  def build_run(group, stack_key:, values:, status: "completed", start_on: Date.new(2026, 6, 1))
    run = group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: stack_key,
      scenario_stack_snapshot: { "key" => stack_key },
      status: status == "failed" ? "running" : "running",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: forecast_valid_input_snapshot(@family)
    )

    values.each_with_index do |attrs, i|
      period_start = start_on >> i # advance i calendar months deterministically
      run.forecast_months.create!(
        period_start_on: period_start,
        period_end_on: period_start.end_of_month,
        precision: "monthly",
        scenario_stack_key: stack_key,
        currency: @family.currency,
        net_worth: attrs.fetch(:net_worth, 0),
        cash_balance: attrs.fetch(:cash_balance, 0),
        debt_balance: attrs.fetch(:debt_balance, 0),
        risk_flags: []
      )
    end

    run.update!(status: status == "failed" ? "failed" : "completed", finished_at: Time.current)
    run
  end

  def new_group
    @family.forecast_run_groups.create!(
      user: @user,
      name: "Comparison run",
      run_type: "manual",
      currency: @family.currency,
      horizon_start_on: Date.new(2026, 6, 1),
      horizon_end_on: Date.new(2029, 6, 1),
      daily_until_on: Date.new(2026, 8, 30)
    )
  end

  def builder_for(group)
    Forecast::DistributionBandBuilder.new(runs: group.forecast_runs.includes(:forecast_months))
  end

  # --- three stacks: low/mid/high == min/median/max per month, with sources ----

  test "three stacks band low/mid/high to the per-month min/median/max with attributed sources" do
    group = new_group
    # Month 0 net worths: low=baseline(5000) mid=upside(7000) high=downside(9000).
    # Month 1 net worths: low=upside(6000) mid=downside(8000) high=baseline(10000).
    build_run(group, stack_key: "baseline", values: [
      { net_worth: 5000 }, { net_worth: 10000 }
    ])
    build_run(group, stack_key: "downside", values: [
      { net_worth: 9000 }, { net_worth: 8000 }
    ])
    build_run(group, stack_key: "upside", values: [
      { net_worth: 7000 }, { net_worth: 6000 }
    ])
    group.update!(status: "completed", finished_at: Time.current)

    points = builder_for(group).band(:net_worth).points
    assert_equal 2, points.size

    m0 = points.first
    assert_equal 5000.to_d, m0.deterministic_low
    assert_equal 7000.to_d, m0.deterministic_mid
    assert_equal 9000.to_d, m0.deterministic_high
    assert_equal "baseline", m0.low_stack_key
    assert_equal "upside", m0.mid_stack_key
    assert_equal "downside", m0.high_stack_key

    m1 = points.last
    assert_equal 6000.to_d, m1.deterministic_low
    assert_equal 8000.to_d, m1.deterministic_mid
    assert_equal 10000.to_d, m1.deterministic_high
    assert_equal "upside", m1.low_stack_key
    assert_equal "downside", m1.mid_stack_key
    assert_equal "baseline", m1.high_stack_key
  end

  test "bands every metric independently (net_worth, cash_balance, debt_balance)" do
    group = new_group
    build_run(group, stack_key: "baseline", values: [ { net_worth: 5000, cash_balance: 100, debt_balance: 900 } ])
    build_run(group, stack_key: "downside", values: [ { net_worth: 9000, cash_balance: 300, debt_balance: 700 } ])
    group.update!(status: "completed", finished_at: Time.current)

    builder = builder_for(group)

    cash = builder.band(:cash_balance).points.first
    assert_equal 100.to_d, cash.deterministic_low
    assert_equal 300.to_d, cash.deterministic_high
    assert_equal "baseline", cash.low_stack_key
    assert_equal "downside", cash.high_stack_key

    debt = builder.band(:debt_balance).points.first
    assert_equal 700.to_d, debt.deterministic_low
    assert_equal 900.to_d, debt.deterministic_high
    assert_equal "downside", debt.low_stack_key
    assert_equal "baseline", debt.high_stack_key
  end

  # --- degenerate single stack: low == mid == high ---------------------------

  test "single stack yields degenerate bands where low == mid == high" do
    group = new_group
    build_run(group, stack_key: "baseline", values: [ { net_worth: 5000 }, { net_worth: 5100 } ])
    group.update!(status: "completed", finished_at: Time.current)

    points = builder_for(group).band(:net_worth).points
    assert_equal 2, points.size
    points.each do |point|
      assert_equal point.deterministic_low, point.deterministic_mid
      assert_equal point.deterministic_mid, point.deterministic_high
      assert_equal "baseline", point.low_stack_key
      assert_equal "baseline", point.high_stack_key
    end
    assert_equal 5000.to_d, points.first.deterministic_low
    assert_equal 5100.to_d, points.last.deterministic_high
  end

  # --- failed stack excluded: does not poison min/max ------------------------

  test "a failed run in the group is excluded and cannot poison min or max" do
    group = new_group
    build_run(group, stack_key: "baseline", values: [ { net_worth: 5000 } ])
    build_run(group, stack_key: "downside", values: [ { net_worth: 9000 } ])
    # A failed stack with no months would otherwise read as a zero band edge.
    group.forecast_runs.create!(
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
    # Group stays non-completed: a group with a failed run cannot flip to
    # completed (it would fail completed_group_has_completed_runs). The builder
    # reads the runs directly, so it bands the completed stacks regardless.

    point = builder_for(group).band(:net_worth).points.first
    assert_equal 5000.to_d, point.deterministic_low, "failed (zero) stack must not become the low"
    assert_equal 9000.to_d, point.deterministic_high
    assert_equal %w[baseline downside], point.contributing_stack_keys.sort
    assert_not_includes point.contributing_stack_keys, "failed_stack"
  end

  # --- differing month counts: only common months, with a note ----------------

  test "stacks with differing month counts band only the common months with a note" do
    group = new_group
    build_run(group, stack_key: "baseline", values: [ { net_worth: 5000 }, { net_worth: 5100 }, { net_worth: 5200 } ])
    build_run(group, stack_key: "downside", values: [ { net_worth: 9000 }, { net_worth: 9100 } ])
    group.update!(status: "completed", finished_at: Time.current)

    band = builder_for(group).band(:net_worth)
    assert_equal 2, band.points.size, "spans only the two months common to both stacks"
    assert_equal [ Date.new(2026, 6, 1), Date.new(2026, 7, 1) ], band.points.map(&:period_start_on)
    assert_equal I18n.t("forecasts.distribution.trimmed_to_common_months_note"), band.note
  end

  test "fully-aligned stacks carry no trim note" do
    group = new_group
    build_run(group, stack_key: "baseline", values: [ { net_worth: 5000 } ])
    build_run(group, stack_key: "downside", values: [ { net_worth: 9000 } ])
    group.update!(status: "completed", finished_at: Time.current)

    assert_nil builder_for(group).band(:net_worth).note
  end

  # --- deterministic ordering by period_start_on ------------------------------

  test "points are ordered by period_start_on regardless of row insertion order" do
    group = new_group
    # Insert months out of chronological order to prove ordering is by date.
    run = group.forecast_runs.create!(
      family: @family, user: @user, scenario_stack_key: "baseline",
      scenario_stack_snapshot: { "key" => "baseline" }, status: "running",
      feasibility_status: "pass", currency: @family.currency,
      input_snapshot: forecast_valid_input_snapshot(@family)
    )
    [ Date.new(2026, 8, 1), Date.new(2026, 6, 1), Date.new(2026, 7, 1) ].each_with_index do |period_start, i|
      run.forecast_months.create!(
        period_start_on: period_start, period_end_on: period_start.end_of_month,
        precision: "monthly", scenario_stack_key: "baseline", currency: @family.currency,
        net_worth: 5000 + (i * 10), cash_balance: 0, debt_balance: 0, risk_flags: []
      )
    end
    run.update!(status: "completed", finished_at: Time.current)
    group.update!(status: "completed", finished_at: Time.current)

    starts = builder_for(group).band(:net_worth).points.map(&:period_start_on)
    assert_equal [ Date.new(2026, 6, 1), Date.new(2026, 7, 1), Date.new(2026, 8, 1) ], starts
  end

  # --- empty group: empty bands -----------------------------------------------

  test "empty group yields empty bands for every metric" do
    group = new_group
    group.update!(status: "completed", finished_at: Time.current) if group.forecast_runs.any?

    builder = builder_for(group)
    Forecast::DistributionBandBuilder::METRICS.each do |metric|
      band = builder.band(metric)
      assert_empty band.points
      assert_equal I18n.t("forecasts.distribution.empty_band_note"), band.note
    end
    assert_not builder.any?
  end

  test "a group whose only stacks all failed yields empty bands" do
    group = new_group
    group.forecast_runs.create!(
      family: @family, user: @user, scenario_stack_key: "failed_stack",
      scenario_stack_snapshot: { "key" => "failed_stack" }, status: "failed",
      feasibility_status: "unknown", currency: @family.currency,
      error_message: "boom", input_snapshot: forecast_valid_input_snapshot(@family)
    )

    builder = builder_for(group)
    assert_empty builder.band(:net_worth).points
    assert_not builder.any?
  end

  # --- no recompute / no RNG / no Time.current: same output on repeat ----------

  test "never invokes the engine (reads persisted rows only)" do
    group = new_group
    build_run(group, stack_key: "baseline", values: [ { net_worth: 5000 } ])
    build_run(group, stack_key: "downside", values: [ { net_worth: 9000 } ])
    group.update!(status: "completed", finished_at: Time.current)

    Forecast::Engine.any_instance.expects(:call).never

    builder_for(group).bands
  end

  test "is fully deterministic: identical inputs produce identical band output" do
    group = new_group
    build_run(group, stack_key: "baseline", values: [ { net_worth: 5000, cash_balance: 100, debt_balance: 900 }, { net_worth: 5100, cash_balance: 110, debt_balance: 890 } ])
    build_run(group, stack_key: "downside", values: [ { net_worth: 9000, cash_balance: 300, debt_balance: 700 }, { net_worth: 8000, cash_balance: 250, debt_balance: 720 } ])
    build_run(group, stack_key: "upside", values: [ { net_worth: 7000, cash_balance: 200, debt_balance: 800 }, { net_worth: 6000, cash_balance: 150, debt_balance: 810 } ])
    group.update!(status: "completed", finished_at: Time.current)

    serialize = lambda do
      builder = builder_for(group)
      Forecast::DistributionBandBuilder::METRICS.map do |metric|
        builder.band(metric).points.map do |p|
          [ p.period_start_on, p.deterministic_low, p.deterministic_mid, p.deterministic_high, p.low_stack_key, p.mid_stack_key, p.high_stack_key ]
        end
      end
    end

    first = serialize.call
    second = serialize.call
    assert_equal first, second, "same persisted rows must yield identical bands across builds"
  end

  test "median for an even number of stacks is a deterministic lower-median real value" do
    group = new_group
    # Four stacks, month 0 net worths: 5000, 6000, 7000, 8000.
    # Lower-median of an even set picks the lower-middle element -> 6000.
    build_run(group, stack_key: "baseline", values: [ { net_worth: 5000 } ])
    build_run(group, stack_key: "aaa", values: [ { net_worth: 6000 } ])
    build_run(group, stack_key: "bbb", values: [ { net_worth: 7000 } ])
    build_run(group, stack_key: "ccc", values: [ { net_worth: 8000 } ])
    group.update!(status: "completed", finished_at: Time.current)

    point = builder_for(group).band(:net_worth).points.first
    assert_equal 5000.to_d, point.deterministic_low
    assert_equal 8000.to_d, point.deterministic_high
    assert_equal 6000.to_d, point.deterministic_mid, "lower-median picks the lower-middle stack value"
    assert_equal "aaa", point.mid_stack_key
  end
end
