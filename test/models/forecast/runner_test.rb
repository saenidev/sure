require "test_helper"

class Forecast::RunnerTest < ActiveSupport::TestCase
  test "persists a completed baseline run group with day month category and goal rows" do
    family = families(:dylan_family)
    user = users(:family_admin)

    group = Forecast::Runner.new(
      family: family,
      user: user,
      scenario_stacks: [ [] ],
      run_type: "manual",
      name: "Manual baseline",
      trigger_metadata: { "source" => "manual_button" }
    ).call

    assert_equal "completed", group.status
    assert_equal family.currency, group.currency
    assert_equal "manual_button", group.trigger_metadata.fetch("source")
    assert_equal 1, group.forecast_runs.count
    assert group.forecast_review.present?
    assert_equal "manual", group.forecast_review.source
    assert_equal "manual_button", group.forecast_review.request_packet.fetch("trigger_metadata").fetch("source")

    run = group.forecast_runs.first
    assert_equal "completed", run.status
    assert_includes %w[pass warn blocked], run.feasibility_status
    assert_equal family.currency, run.currency
    assert_equal 90, run.forecast_days.count
    assert_equal 36, run.forecast_months.count
    assert run.forecast_days.first.net_worth.present?

    balance_only_debt_rows = run.forecast_months.flat_map(&:forecast_debt_projections).select { |projection| projection.source == "account_balance_only" }
    if balance_only_debt_rows.any?
      assert group.risk_flags.any? { |flag| flag["type"] == "debt_projection_incomplete" }
    end
  end

  test "persists forecast effect category projections without inherited budget rows" do
    family = families(:dylan_family)
    user = users(:family_admin)
    scenario = family.forecast_scenarios.create!(
      created_by_user: user,
      name: "Unbudgeted move cost",
      starts_on: Date.current,
      position: 1
    )
    family.forecast_events.create!(
      forecast_scenario: scenario,
      category: categories(:income),
      name: "Unbudgeted deposit",
      effect_type: "expense",
      behavior: "additive",
      amount: 300,
      currency: family.currency,
      starts_on: Date.current
    )

    group = Forecast::Runner.new(
      family: family,
      user: user,
      scenario_stacks: [ [ scenario.id ] ],
      run_type: "manual",
      name: "Unbudgeted category"
    ).call

    run = group.forecast_runs.first
    projection = run.forecast_months.order(:period_start_on).first.forecast_category_projections.find_by!(
      category: categories(:income),
      source: "forecast_effect"
    )

    assert_equal 300.to_d, projection.planned_spending
  end

  test "fails the run group loudly when a nonzero amount cannot be converted to family currency" do
    family = families(:dylan_family)
    user = users(:family_admin)
    scenario = family.forecast_scenarios.create!(
      created_by_user: user,
      name: "Foreign expense",
      starts_on: Date.current,
      position: 1
    )
    family.forecast_events.create!(
      forecast_scenario: scenario,
      name: "Unconvertible cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 500,
      currency: "EUR",
      starts_on: Date.current
    )

    # The forecast must fail loudly rather than silently treating EUR as USD.
    ExchangeRate.stubs(:find_or_fetch_rate).with(from: "EUR", to: family.currency, date: anything, cache: false).returns(nil)

    runner = Forecast::Runner.new(
      family: family,
      user: user,
      scenario_stacks: [ [ scenario.id ] ],
      run_type: "manual",
      name: "FX failure"
    )

    error = assert_raises Forecast::MoneyConverter::MissingRate do
      runner.call
    end

    assert_match(/Missing FX rate EUR->#{family.currency}/, error.message)

    group = family.forecast_run_groups.order(:created_at).last
    group.reload
    assert_equal "failed", group.status
    assert group.error_message.present?
    assert_match(/Missing FX rate EUR->#{family.currency}/, group.error_message)

    # The persistence transaction must roll back: no generated rows survive a failed run.
    persisted_runs = group.forecast_runs.reload
    persisted_runs.each { |run| assert_equal "failed", run.status }
    assert_equal 0, ForecastDay.where(forecast_run: persisted_runs).count
    assert_equal 0, ForecastMonth.where(forecast_run: persisted_runs).count
  end

  test "a single failing stack does not roll back its completed siblings (partial failure)" do
    family = families(:dylan_family)
    user = users(:family_admin)

    # One scenario whose event cannot be FX-converted -> its stack fails. The
    # baseline stack ([]) has no such event -> it completes.
    failing_scenario = family.forecast_scenarios.create!(
      created_by_user: user,
      name: "Foreign expense",
      starts_on: Date.current,
      position: 1
    )
    family.forecast_events.create!(
      forecast_scenario: failing_scenario,
      name: "Unconvertible cost",
      effect_type: "expense",
      behavior: "additive",
      amount: 500,
      currency: "EUR",
      starts_on: Date.current
    )
    ExchangeRate.stubs(:find_or_fetch_rate).with(from: "EUR", to: family.currency, date: anything, cache: false).returns(nil)

    # The baseline stack must NOT be rolled back by the failing scenario stack.
    group = Forecast::Runner.new(
      family: family,
      user: user,
      scenario_stacks: [ [], [ failing_scenario.id ] ],
      run_type: "manual",
      name: "Partial failure"
    ).call

    group.reload
    # The group is failed (a stack errored) but it is NOT a total failure: it
    # carries the completed baseline stack alongside a persisted failed marker.
    assert_equal "failed", group.status
    assert group.error_message.present?

    runs = group.forecast_runs.to_a
    completed = runs.select { |run| run.status == "completed" }
    failed = runs.select { |run| run.status == "failed" }

    assert_equal 1, completed.size, "the baseline stack must survive the sibling failure"
    assert_equal 1, failed.size, "the failed stack must persist a marker so the comparison can flag it"
    assert_equal "baseline", completed.first.scenario_stack_key

    # The completed stack's output rows survive (they were NOT rolled back).
    assert_equal 36, completed.first.forecast_months.count
    assert_equal 90, completed.first.forecast_days.count
    # The failed marker carries no output rows.
    assert_equal 0, failed.first.forecast_months.count
    assert_equal 0, failed.first.forecast_days.count
  end

  test "rejects empty scenario stack lists" do
    error = assert_raises ArgumentError do
      Forecast::Runner.new(
        family: families(:dylan_family),
        user: users(:family_admin),
        scenario_stacks: [],
        run_type: "manual",
        name: "Empty run"
      ).call
    end

    assert_equal "scenario_stacks must include at least one stack", error.message
  end
end
