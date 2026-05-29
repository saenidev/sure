require "test_helper"

class Forecast::MaterialMovementTest < ActiveSupport::TestCase
  # The PORO reads only persisted-shaped day rows off each group's baseline run,
  # so we drive it with lightweight doubles to keep the test fast and isolated
  # from the engine. A "group" responds to #forecast_runs; a "run" responds to
  # #scenario_stack_key, #completed?, and #forecast_days.
  DayDouble = Struct.new(:date, :portfolio_value, :net_worth, :debt_balance, :cash_runway_days, keyword_init: true)

  def run_double(days:, key: "baseline", completed: true)
    OpenStruct.new(scenario_stack_key: key, completed?: completed, forecast_days: days)
  end

  def group_double(runs:)
    OpenStruct.new(forecast_runs: runs)
  end

  def baseline_group(portfolio:, net_worth: 1000, debt: 0, runway: 100, date: Date.current)
    day = DayDouble.new(date: date, portfolio_value: portfolio, net_worth: net_worth, debt_balance: debt, cash_runway_days: runway)
    group_double(runs: [ run_double(days: [ day ]) ])
  end

  test "portfolio day-change above threshold is material" do
    current = baseline_group(portfolio: 110_000)   # +10% vs 100k, threshold 5%
    previous = baseline_group(portfolio: 100_000)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert result.material?, "expected a 10% portfolio change to be material"
    assert_includes result.reasons, "portfolio_value_change"
  end

  test "portfolio day-change below threshold is not material" do
    current = baseline_group(portfolio: 102_000)   # +2% vs 100k, threshold 5%
    previous = baseline_group(portfolio: 100_000)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert_not result.material?, "expected a 2% portfolio change to be immaterial"
    assert_empty result.reasons
  end

  test "a large drop is just as material as a gain" do
    current = baseline_group(portfolio: 90_000)    # -10% vs 100k
    previous = baseline_group(portfolio: 100_000)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert result.material?, "expected a 10% drop to be material"
    assert_includes result.reasons, "portfolio_value_change"
  end

  test "missing previous group is treated as material (first run default)" do
    current = baseline_group(portfolio: 100_000)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: nil).call

    assert result.material?, "first market-close run should be material by default"
    assert_includes result.reasons, "no_previous_group"
  end

  test "missing previous group honors the configured non-material default" do
    current = baseline_group(portfolio: 100_000)
    thresholds = Forecast::MaterialMovement.thresholds.merge(on_missing_baseline: false)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: nil, thresholds: thresholds).call

    assert_not result.material?, "should respect on_missing_baseline=false"
    assert_empty result.reasons
  end

  test "net worth change above threshold is material even when portfolio is flat" do
    current = baseline_group(portfolio: 100_000, net_worth: 1_100)   # +10% vs 1000, threshold 3%
    previous = baseline_group(portfolio: 100_000, net_worth: 1_000)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert result.material?
    assert_includes result.reasons, "net_worth_change"
    assert_not_includes result.reasons, "portfolio_value_change"
  end

  test "cash runway change beyond the day threshold is material" do
    current = baseline_group(portfolio: 100_000, runway: 60)    # -40 days vs 100, threshold 14
    previous = baseline_group(portfolio: 100_000, runway: 100)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert result.material?
    assert_includes result.reasons, "cash_runway_days_change"
  end

  test "nil runway on either side does not flag runway movement" do
    current = baseline_group(portfolio: 100_000, runway: nil)
    previous = baseline_group(portfolio: 100_000, runway: 100)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert_not result.material?, "cannot compute a runway delta when one side is nil"
    assert_not_includes result.reasons, "cash_runway_days_change"
  end

  test "movement off a zero portfolio base is material" do
    current = baseline_group(portfolio: 5_000)
    previous = baseline_group(portfolio: 0)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert result.material?, "going from zero to non-zero is an unbounded change"
    assert_includes result.reasons, "portfolio_value_change"
  end

  test "no current baseline day yields a non-material result" do
    current = group_double(runs: [])
    previous = baseline_group(portfolio: 100_000)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert_not result.material?
    assert_empty result.reasons
  end

  test "uses the first projected day and falls back off the baseline stack key" do
    # The min-by-date day is the snapshot; a later day must not be used.
    early = DayDouble.new(date: Date.current, portfolio_value: 100_000, net_worth: 1, debt_balance: 0, cash_runway_days: 100)
    late = DayDouble.new(date: Date.current + 30, portfolio_value: 999_999, net_worth: 1, debt_balance: 0, cash_runway_days: 100)
    current = group_double(runs: [ run_double(days: [ late, early ]) ])
    previous = baseline_group(portfolio: 100_000, net_worth: 1)

    result = Forecast::MaterialMovement.new(current_group: current, previous_group: previous).call

    assert_not result.material?, "should compare the first day (100k vs 100k), not the late day"
  end
end
