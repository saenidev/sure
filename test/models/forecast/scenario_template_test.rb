require "test_helper"

class Forecast::ScenarioTemplateTest < ActiveSupport::TestCase
  setup do
    @currency = "USD"
  end

  EXPECTED_KEYS = %w[
    country_move job_change income_loss major_purchase
    market_drawdown liquidity_stress tax_placeholder
  ].freeze

  test "catalog lists exactly the expected preset keys in stable order" do
    assert_equal EXPECTED_KEYS, Forecast::ScenarioTemplate.keys
  end

  test "find returns nil for an unknown key and find! raises" do
    assert_nil Forecast::ScenarioTemplate.find("nope")
    assert_raises(Forecast::ScenarioTemplate::InvalidParams) do
      Forecast::ScenarioTemplate.find!("nope")
    end
  end

  test "every preset builder produces only allowed effect and goal types" do
    plans = {
      "country_move" => { "move_on" => "2026-06-01", "moving_cost" => "5000", "monthly_cost_delta" => "300" },
      "job_change" => { "starts_on" => "2026-06-01", "new_monthly_salary" => "8000", "old_monthly_salary" => "6000" },
      "income_loss" => { "starts_on" => "2026-06-01", "lost_monthly_income" => "6000", "runway_floor_days" => "90" },
      "major_purchase" => { "purchase_on" => "2026-06-01", "purchase_amount" => "30000" },
      "market_drawdown" => { "starts_on" => "2026-06-01", "drawdown_pct" => "30", "portfolio_value" => "100000" },
      "liquidity_stress" => { "starts_on" => "2026-06-01", "monthly_shortfall" => "2000", "liquid_runway_floor_days" => "60" },
      "tax_placeholder" => { "effective_on" => "2026-06-01" }
    }

    Forecast::ScenarioTemplate.keys.each do |key|
      template = Forecast::ScenarioTemplate.find(key)
      plan = template.build_plan(plans.fetch(key), currency: @currency)

      assert plan[:scenario][:name].present?, "#{key} scenario must have a name"

      plan[:events].each do |event|
        assert_includes ForecastEvent::EFFECT_TYPES, event[:effect_type],
          "#{key} produced disallowed effect_type #{event[:effect_type]}"
      end

      plan[:goals].each do |goal|
        assert_includes ForecastGoal::GOAL_TYPES, goal[:goal_type],
          "#{key} produced disallowed goal_type #{goal[:goal_type]}"
      end
    end
  end

  test "market_drawdown computes a negative signed market_shock from pct and value" do
    plan = Forecast::ScenarioTemplate.find("market_drawdown").build_plan(
      { "starts_on" => "2026-06-01", "drawdown_pct" => "30", "portfolio_value" => "100000" },
      currency: @currency
    )

    shock = plan[:events].first
    assert_equal "market_shock", shock[:effect_type]
    assert_equal BigDecimal("-30000"), shock[:amount]
  end

  test "building a plan is deterministic for the same params" do
    params = { "purchase_on" => "2026-06-01", "purchase_amount" => "30000" }
    template = Forecast::ScenarioTemplate.find("major_purchase")

    assert_equal(
      template.build_plan(params, currency: @currency),
      template.build_plan(params, currency: @currency)
    )
  end

  # --- param validation ------------------------------------------------------

  test "rejects a blank required date" do
    error = assert_raises(Forecast::ScenarioTemplate::InvalidParams) do
      Forecast::ScenarioTemplate.find("country_move").build_plan(
        { "move_on" => "", "moving_cost" => "5000" }, currency: @currency
      )
    end
    assert error.errors.any? { |m| m.include?("Move date") }, error.errors.inspect
  end

  test "rejects an unparseable date" do
    error = assert_raises(Forecast::ScenarioTemplate::InvalidParams) do
      Forecast::ScenarioTemplate.find("major_purchase").build_plan(
        { "purchase_on" => "not-a-date", "purchase_amount" => "10" }, currency: @currency
      )
    end
    assert error.errors.any?, error.errors.inspect
  end

  test "rejects a non-positive amount" do
    assert_raises(Forecast::ScenarioTemplate::InvalidParams) do
      Forecast::ScenarioTemplate.find("major_purchase").build_plan(
        { "purchase_on" => "2026-06-01", "purchase_amount" => "-5" }, currency: @currency
      )
    end
  end

  test "rejects a negative drawdown percentage" do
    assert_raises(Forecast::ScenarioTemplate::InvalidParams) do
      Forecast::ScenarioTemplate.find("market_drawdown").build_plan(
        { "starts_on" => "2026-06-01", "drawdown_pct" => "-10", "portfolio_value" => "100000" },
        currency: @currency
      )
    end
  end

  test "rejects a drawdown percentage above 100" do
    assert_raises(Forecast::ScenarioTemplate::InvalidParams) do
      Forecast::ScenarioTemplate.find("market_drawdown").build_plan(
        { "starts_on" => "2026-06-01", "drawdown_pct" => "150", "portfolio_value" => "100000" },
        currency: @currency
      )
    end
  end

  test "optional params fall back to declared defaults" do
    plan = Forecast::ScenarioTemplate.find("income_loss").build_plan(
      { "starts_on" => "2026-06-01", "lost_monthly_income" => "6000" }, currency: @currency
    )

    # runway_floor_days defaults to 90, producing a runway goal.
    goal = plan[:goals].first
    assert_equal "minimum_cash_runway", goal[:goal_type]
    assert_equal 90, goal[:target_duration_days]
    assert_equal 90, plan[:params]["runway_floor_days"]
  end
end
