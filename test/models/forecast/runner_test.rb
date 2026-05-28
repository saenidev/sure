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
