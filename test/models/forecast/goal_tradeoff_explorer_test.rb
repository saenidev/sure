require "test_helper"

class Forecast::GoalTradeoffExplorerTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @family.forecast_run_groups.delete_all
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

  # Builds a (by default completed) run carrying immutable goal evaluations.
  # Evaluations are written while the run is non-completed (immutability only
  # locks completed output) then the run is flipped, mirroring the Runner.
  # `goals` is an array of hashes: { key:, status:, metric_value: nil, goal_type:, field: }.
  def build_run(group, stack_key:, goals:, status: "completed", label: nil)
    run = group.forecast_runs.create!(
      family: @family,
      user: @user,
      scenario_stack_key: stack_key,
      scenario_stack_snapshot: ({ "key" => stack_key }.tap { |s| s["label"] = label if label }),
      status: "running",
      feasibility_status: "pass",
      currency: @family.currency,
      input_snapshot: forecast_valid_input_snapshot(@family)
    )

    goals.each do |attrs|
      run.forecast_goal_evaluations.create!(
        goal_key: attrs.fetch(:key),
        scenario_stack_key: stack_key,
        status: attrs.fetch(:status),
        currency: @family.currency,
        metric_value: attrs[:metric_value],
        target_value: attrs[:target_value],
        goal_snapshot: { "goal_type" => attrs.fetch(:goal_type, "minimum_cash_runway") },
        details: { "field" => attrs.fetch(:field, "cash_runway_days") }
      )
    end

    run.update!(status: status == "failed" ? "failed" : "completed", finished_at: Time.current)
    run
  end

  def explorer_for(group, goal_keys: nil)
    Forecast::GoalTradeoffExplorer.new(
      runs: group.forecast_runs.includes(:forecast_goal_evaluations),
      goal_keys: goal_keys
    )
  end

  # --- a stack satisfying all goals ranks first ------------------------------

  test "a stack that satisfies all goals ranks first" do
    group = new_group
    build_run(group, stack_key: "baseline", goals: [
      { key: "goal_a", status: "pass" },
      { key: "goal_b", status: "warn" }
    ])
    build_run(group, stack_key: "upside", goals: [
      { key: "goal_a", status: "pass" },
      { key: "goal_b", status: "pass" }
    ])
    group.update!(status: "completed", finished_at: Time.current)

    result = explorer_for(group).explore
    assert_equal "upside", result.first[:stack_key]
    assert_equal %w[goal_a goal_b], result.first[:satisfied_goal_keys]
    assert_empty result.first[:at_risk_goal_keys]
    assert_empty result.first[:blocked_goal_keys]
  end

  # --- a blocking goal sinks the stack regardless of other satisfied goals ----

  test "a stack with a blocking goal ranks last even with many satisfied goals" do
    group = new_group
    # Blocked stack satisfies MORE goals than the winner, but a blocked goal sinks it.
    build_run(group, stack_key: "aaa_blocked", goals: [
      { key: "goal_a", status: "pass" },
      { key: "goal_b", status: "pass" },
      { key: "goal_c", status: "blocking" }
    ])
    build_run(group, stack_key: "zzz_clean", goals: [
      { key: "goal_a", status: "pass" },
      { key: "goal_b", status: "warn" },
      { key: "goal_c", status: "warn" }
    ])
    group.update!(status: "completed", finished_at: Time.current)

    result = explorer_for(group).explore
    assert_equal "zzz_clean", result.first[:stack_key], "blocked stack must not rank first despite satisfying more goals"
    assert_equal "aaa_blocked", result.last[:stack_key]
    assert_equal %w[goal_c], result.last[:blocked_goal_keys]
    assert_equal %w[goal_a goal_b], result.last[:satisfied_goal_keys]
  end

  # --- tie-break: same satisfied count -> blocked count then stack key --------

  test "stacks with the same satisfied count tie-break by blocked count then stack key" do
    group = new_group
    # All three satisfy exactly 1 goal. zeta has a block (sinks to last among ties).
    # alpha and gamma both clean -> ordered by stack key ascending.
    build_run(group, stack_key: "gamma", goals: [
      { key: "goal_a", status: "pass" }, { key: "goal_b", status: "warn" }
    ])
    build_run(group, stack_key: "alpha", goals: [
      { key: "goal_a", status: "pass" }, { key: "goal_b", status: "fail" }
    ])
    build_run(group, stack_key: "zeta", goals: [
      { key: "goal_a", status: "pass" }, { key: "goal_b", status: "blocking" }
    ])
    group.update!(status: "completed", finished_at: Time.current)

    keys = explorer_for(group).explore.map { |r| r[:stack_key] }
    assert_equal %w[alpha gamma zeta], keys, "1 satisfied each: clean stacks by key asc, blocked last"
  end

  # --- tradeoff notes capture an improvement on one goal and a regression -----

  test "tradeoff notes capture a metric improvement on one goal alongside a regression on another" do
    group = new_group
    # Baseline reference. Runway goal: 120 days; debt goal: 5000 owed.
    build_run(group, stack_key: "baseline", goals: [
      { key: "runway", status: "pass", metric_value: 120, goal_type: "minimum_cash_runway", field: "cash_runway_days" },
      { key: "debt_payoff", status: "pass", metric_value: 5000, goal_type: "maximum_debt_balance", field: "debt_balance" }
    ])
    # Candidate buys +60 days of runway (improvement) but pushes debt UP to 6000
    # (regression for a maximum-debt goal, where lower is better).
    build_run(group, stack_key: "aggressive", goals: [
      { key: "runway", status: "pass", metric_value: 180, goal_type: "minimum_cash_runway", field: "cash_runway_days" },
      { key: "debt_payoff", status: "pass", metric_value: 6000, goal_type: "maximum_debt_balance", field: "debt_balance" }
    ])
    group.update!(status: "completed", finished_at: Time.current)

    result = explorer_for(group).explore
    aggressive = result.find { |r| r[:stack_key] == "aggressive" }
    notes = aggressive[:tradeoff_notes].index_by { |n| n[:goal_key] }

    runway = notes.fetch("runway")
    assert_equal "improvement", runway[:direction]
    assert_equal 60.to_d, runway[:metric_delta]
    assert_equal "cash_runway_days", runway[:field]

    debt = notes.fetch("debt_payoff")
    assert_equal "regression", debt[:direction], "more debt is worse for a maximum-debt goal"
    assert_equal 1000.to_d, debt[:metric_delta]

    # The baseline stack itself is the reference and carries no tradeoff notes.
    baseline = result.find { |r| r[:stack_key] == "baseline" }
    assert_empty baseline[:tradeoff_notes]
  end

  # --- failed run excluded from ranking ---------------------------------------

  test "a failed run is excluded from the ranking" do
    group = new_group
    build_run(group, stack_key: "baseline", goals: [ { key: "goal_a", status: "pass" } ])
    build_run(group, stack_key: "failed_stack", goals: [ { key: "goal_a", status: "pass" } ], status: "failed")
    # Group stays non-completed (a failed run cannot flip the group to completed).

    keys = explorer_for(group).explore.map { |r| r[:stack_key] }
    assert_equal %w[baseline], keys
    assert_not_includes keys, "failed_stack"
  end

  # --- unknown/warn state classified as at_risk; un-evaluated goals are N/A -----

  test "an evaluated warn goal is at_risk while a goal this stack never graded is N/A" do
    group = new_group
    # goal_warn -> warn (evaluated), goal_missing -> not evaluated at all by candidate.
    build_run(group, stack_key: "baseline", goals: [
      { key: "goal_warn", status: "warn" },
      { key: "goal_missing", status: "pass" } # evaluated here so it enters the universe
    ])
    build_run(group, stack_key: "candidate", goals: [
      { key: "goal_warn", status: "warn" }
      # goal_missing intentionally NOT evaluated by this stack
    ])
    group.update!(status: "completed", finished_at: Time.current)

    candidate = explorer_for(group).explore.find { |r| r[:stack_key] == "candidate" }
    assert_empty candidate[:satisfied_goal_keys], "a warn goal is never satisfied"
    # Only the goal candidate actually evaluated (goal_warn) is at_risk. The goal it
    # never graded (goal_missing) is NOT APPLICABLE and excluded from at_risk.
    assert_equal %w[goal_warn], candidate[:at_risk_goal_keys]
    assert_not_includes candidate[:at_risk_goal_keys], "goal_missing",
      "a goal this stack never evaluated is N/A, not at_risk"
    assert_empty candidate[:blocked_goal_keys]
  end

  # --- un-evaluated goals are N/A (not at_risk) on the run that skipped them ---

  test "a scenario-only goal is not counted at_risk on the baseline row that never evaluated it" do
    group = new_group
    # The baseline run evaluates only the family-wide goal. The scenario-only goal
    # (graded only by the scenario stack) is NOT APPLICABLE to the baseline and must
    # not be routed into the baseline's at_risk set, which would overstate baseline risk.
    build_run(group, stack_key: "baseline", goals: [
      { key: "family_goal", status: "pass" }
      # scenario_goal intentionally NOT evaluated by the baseline run
    ])
    build_run(group, stack_key: "scenario", goals: [
      { key: "family_goal", status: "pass" },
      { key: "scenario_goal", status: "warn" } # only the scenario stack grades this
    ])
    group.update!(status: "completed", finished_at: Time.current)

    result = explorer_for(group).explore
    baseline = result.find { |r| r[:stack_key] == "baseline" }

    assert_not_includes baseline[:at_risk_goal_keys], "scenario_goal",
      "a goal the baseline never evaluated is N/A, not at_risk, on the baseline row"
    assert_empty baseline[:at_risk_goal_keys],
      "the baseline's at_risk set must exclude goals it never graded"
    assert_equal %w[family_goal], baseline[:satisfied_goal_keys]

    # The scenario stack actually graded scenario_goal as warn -> it IS at_risk there.
    scenario = result.find { |r| r[:stack_key] == "scenario" }
    assert_includes scenario[:at_risk_goal_keys], "scenario_goal"
  end

  # --- empty group -> [] ------------------------------------------------------

  test "empty group yields an empty ranking" do
    group = new_group
    explorer = explorer_for(group)
    assert_equal [], explorer.explore
    assert_not explorer.any?
  end

  test "a group whose only stacks all failed yields an empty ranking" do
    group = new_group
    build_run(group, stack_key: "failed_stack", goals: [ { key: "goal_a", status: "pass" } ], status: "failed")

    explorer = explorer_for(group)
    assert_equal [], explorer.explore
    assert_not explorer.any?
  end

  # --- goal_keys restricts the considered universe ----------------------------

  test "goal_keys restricts ranking to the requested subset" do
    group = new_group
    build_run(group, stack_key: "baseline", goals: [
      { key: "goal_a", status: "pass" },
      { key: "goal_b", status: "blocking" }
    ])
    group.update!(status: "completed", finished_at: Time.current)

    # Restricting to goal_a ignores the blocking goal_b entirely.
    result = explorer_for(group, goal_keys: %w[goal_a]).explore.first
    assert_equal %w[goal_a], result[:satisfied_goal_keys]
    assert_empty result[:blocked_goal_keys]
  end

  # --- determinism: identical ranking on repeat -------------------------------

  test "is fully deterministic: identical inputs produce identical ranking on repeat" do
    group = new_group
    build_run(group, stack_key: "baseline", goals: [
      { key: "runway", status: "pass", metric_value: 120, goal_type: "minimum_cash_runway" },
      { key: "debt", status: "pass", metric_value: 5000, goal_type: "maximum_debt_balance" }
    ])
    build_run(group, stack_key: "aggressive", goals: [
      { key: "runway", status: "pass", metric_value: 180, goal_type: "minimum_cash_runway" },
      { key: "debt", status: "blocking", metric_value: 6000, goal_type: "maximum_debt_balance" }
    ])
    build_run(group, stack_key: "balanced", goals: [
      { key: "runway", status: "warn", metric_value: 90, goal_type: "minimum_cash_runway" },
      { key: "debt", status: "pass", metric_value: 4000, goal_type: "maximum_debt_balance" }
    ])
    group.update!(status: "completed", finished_at: Time.current)

    serialize = lambda do
      explorer_for(group).explore.map do |r|
        [ r[:stack_key], r[:satisfied_goal_keys], r[:at_risk_goal_keys], r[:blocked_goal_keys],
          r[:tradeoff_notes].map { |n| [ n[:goal_key], n[:direction], n[:metric_delta] ] } ]
      end
    end

    assert_equal serialize.call, serialize.call, "same persisted rows must yield identical ranking"
  end

  # --- never invokes the engine -----------------------------------------------

  test "never invokes the engine (reads persisted rows only)" do
    group = new_group
    build_run(group, stack_key: "baseline", goals: [ { key: "goal_a", status: "pass" } ])
    group.update!(status: "completed", finished_at: Time.current)

    Forecast::Engine.any_instance.expects(:call).never
    explorer_for(group).explore
  end
end
