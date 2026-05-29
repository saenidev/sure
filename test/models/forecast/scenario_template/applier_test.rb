require "test_helper"

class Forecast::ScenarioTemplate::ApplierTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  test "apply creates an editable scenario with template provenance recorded" do
    scenario = nil
    assert_difference "@family.forecast_scenarios.count", 1 do
      scenario = Forecast::ScenarioTemplate::Applier.apply!(
        template_key: "major_purchase",
        family: @family,
        user: @user,
        params: { "purchase_on" => "2026-06-01", "purchase_amount" => "30000" }
      )
    end

    assert_equal @family.id, scenario.family_id
    assert_equal @user.id, scenario.created_by_user_id
    assert_equal "manual", scenario.approval_status
    assert_equal "disabled", scenario.status

    assert_equal "template", scenario.source_metadata["source"]
    assert_equal "major_purchase", scenario.source_metadata["template_key"]
    assert_equal "2026-06-01", scenario.source_metadata.dig("params", "purchase_on")
    assert_equal "30000.0", scenario.source_metadata.dig("params", "purchase_amount")

    event = scenario.forecast_events.first
    assert_equal @family.id, event.family_id
    assert_equal "expense", event.effect_type
    assert_equal Date.new(2026, 6, 1), event.starts_on
    assert_equal "template", event.source_metadata["source"]
  end

  test "apply instantiates events and goals scoped to the same family" do
    scenario = Forecast::ScenarioTemplate::Applier.apply!(
      template_key: "income_loss",
      family: @family,
      user: @user,
      params: { "starts_on" => "2026-06-01", "lost_monthly_income" => "6000", "runway_floor_days" => "120" }
    )

    assert scenario.forecast_events.any?
    assert scenario.forecast_goals.any?

    scenario.forecast_events.each { |e| assert_equal @family.id, e.family_id }
    scenario.forecast_goals.each { |g| assert_equal @family.id, g.family_id }

    goal = scenario.forecast_goals.first
    assert_equal "minimum_cash_runway", goal.goal_type
    assert_equal 120, goal.target_duration_days
  end

  test "applying the same template and params twice yields identical planning objects" do
    params = { "starts_on" => "2026-06-01", "new_monthly_salary" => "8000", "old_monthly_salary" => "6000" }

    first = Forecast::ScenarioTemplate::Applier.apply!(
      template_key: "job_change", family: @family, user: @user, params: params
    )
    second = Forecast::ScenarioTemplate::Applier.apply!(
      template_key: "job_change", family: @family, user: @user, params: params
    )

    assert_equal first.source_metadata["params"], second.source_metadata["params"]

    comparable = ->(scenario) do
      scenario.forecast_events.order(:name).map do |e|
        e.attributes.slice("name", "effect_type", "amount", "currency", "starts_on", "ends_on", "recurrence_rule")
      end
    end

    assert_equal comparable.call(first), comparable.call(second)
  end

  test "apply creates no forecast run or month output" do
    assert_no_difference [ "ForecastRun.count", "ForecastMonth.count" ] do
      Forecast::ScenarioTemplate::Applier.apply!(
        template_key: "tax_placeholder",
        family: @family,
        user: @user,
        params: { "effective_on" => "2026-06-01" }
      )
    end
  end

  test "invalid params raise before any record is written" do
    assert_no_difference "@family.forecast_scenarios.count" do
      assert_raises(Forecast::ScenarioTemplate::InvalidParams) do
        Forecast::ScenarioTemplate::Applier.apply!(
          template_key: "major_purchase",
          family: @family,
          user: @user,
          params: { "purchase_on" => "", "purchase_amount" => "30000" }
        )
      end
    end
  end

  test "an invalid child rolls the whole apply back" do
    ForecastEvent.any_instance.stubs(:valid?).returns(false)

    assert_no_difference [ "@family.forecast_scenarios.count", "@family.forecast_events.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        Forecast::ScenarioTemplate::Applier.apply!(
          template_key: "major_purchase",
          family: @family,
          user: @user,
          params: { "purchase_on" => "2026-06-01", "purchase_amount" => "30000" }
        )
      end
    end
  end

  test "applier always scopes to the passed family" do
    other_family = families(:empty)

    scenario = Forecast::ScenarioTemplate::Applier.apply!(
      template_key: "tax_placeholder",
      family: other_family,
      user: nil,
      params: { "effective_on" => "2026-06-01" }
    )

    assert_equal other_family.id, scenario.family_id
    assert_not_equal @family.id, scenario.family_id
  end

  test "unknown template key raises before any write" do
    assert_no_difference "@family.forecast_scenarios.count" do
      assert_raises(Forecast::ScenarioTemplate::InvalidParams) do
        Forecast::ScenarioTemplate::Applier.apply!(
          template_key: "ponzi_scheme", family: @family, user: @user, params: {}
        )
      end
    end
  end
end
