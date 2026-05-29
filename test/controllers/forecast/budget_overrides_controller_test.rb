require "test_helper"

class Forecast::BudgetOverridesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_budget_overrides.delete_all
    @family.forecast_scenarios.delete_all
    @parent_category = categories(:food_and_drink)
    @subcategory = categories(:subcategory)
    @period = Budget.date_to_param(Date.current.beginning_of_month)
    sign_in @user
  end

  def base_params(overrides = {})
    {
      period_start_on: Date.current.beginning_of_month.to_s,
      override_type: "category_spending",
      category_id: @parent_category.id,
      amount: "900",
      currency: @family.currency,
      status: "active"
    }.merge(overrides)
  end

  # --- index -----------------------------------------------------------------

  test "index renders the month grid with income, uncategorized, and parent category rows" do
    get forecast_budget_overrides_path(period: @period)

    assert_response :success
    assert_select "[data-testid=forecast-budget-override-period]"
    # Parent category row present
    assert_select "#forecast_budget_override_category_spending_#{@parent_category.id}_row"
    # Income + uncategorized rows present (no category)
    assert_select "#forecast_budget_override_expected_income_none_row"
    assert_select "#forecast_budget_override_uncategorized_spending_none_row"
    # Subcategories are NOT rendered as their own override rows
    assert_select "#forecast_budget_override_category_spending_#{@subcategory.id}_row", count: 0
  end

  test "index only shows scenarios whose window covers the period in the scenario picker" do
    covering = @family.forecast_scenarios.create!(name: "Covers", status: "active")
    not_covering = @family.forecast_scenarios.create!(
      name: "Partial",
      status: "active",
      starts_on: Date.current.beginning_of_month + 10.days,
      ends_on: Date.current.end_of_month
    )

    get forecast_budget_overrides_path(period: @period)

    assert_response :success
    assert_select "option[value=?]", covering.id.to_s
    assert_select "option[value=?]", not_covering.id.to_s, count: 0
  end

  test "index scopes overrides to the current family" do
    mine = @family.forecast_budget_overrides.create!(base_params(amount: 500))
    get forecast_budget_overrides_path(period: @period)

    assert_response :success
    assert_select "##{dom_id(mine)}"
  end

  # --- create happy paths ----------------------------------------------------

  test "create persists a category_spending override for a parent category" do
    assert_difference "@family.forecast_budget_overrides.count", 1 do
      post forecast_budget_overrides_path, params: { forecast_budget_override: base_params }
    end

    override = @family.forecast_budget_overrides.order(:created_at).last
    assert_equal "category_spending", override.override_type
    assert_equal @parent_category.id, override.category_id
    assert_equal @family.id, override.family_id
    assert_response :redirect
  end

  test "create persists an expected_income override without a category" do
    assert_difference "@family.forecast_budget_overrides.count", 1 do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(override_type: "expected_income", category_id: nil, amount: "6000")
      }
    end

    override = @family.forecast_budget_overrides.order(:created_at).last
    assert_equal "expected_income", override.override_type
    assert_nil override.category_id
  end

  test "create persists an uncategorized_spending override without a category" do
    assert_difference "@family.forecast_budget_overrides.count", 1 do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(override_type: "uncategorized_spending", category_id: nil, amount: "300")
      }
    end

    override = @family.forecast_budget_overrides.order(:created_at).last
    assert_equal "uncategorized_spending", override.override_type
    assert_nil override.category_id
  end

  # --- creating an override does not touch the real budget -------------------

  test "creating an override does not create or modify any Budget or BudgetCategory" do
    assert_no_difference [ "Budget.count", "BudgetCategory.count" ] do
      post forecast_budget_overrides_path, params: { forecast_budget_override: base_params }
    end
  end

  # --- validation / failure surfacing (422) ----------------------------------

  test "category_spending with a subcategory is rejected with a 422" do
    assert_no_difference "@family.forecast_budget_overrides.count" do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(category_id: @subcategory.id)
      }
    end

    assert_response :unprocessable_entity
  end

  test "category_spending without a category is rejected with a 422" do
    assert_no_difference "@family.forecast_budget_overrides.count" do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(category_id: nil)
      }
    end

    assert_response :unprocessable_entity
  end

  test "expected_income with a category is rejected with a 422" do
    assert_no_difference "@family.forecast_budget_overrides.count" do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(override_type: "expected_income")
      }
    end

    assert_response :unprocessable_entity
  end

  test "negative amount is rejected with a 422" do
    assert_no_difference "@family.forecast_budget_overrides.count" do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(amount: "-100")
      }
    end

    assert_response :unprocessable_entity
  end

  # --- duplicate active override is surfaced (not 500) -----------------------

  test "a duplicate active override surfaces the uniqueness error and offers to edit the existing" do
    existing = @family.forecast_budget_overrides.create!(base_params)

    assert_no_difference "@family.forecast_budget_overrides.count" do
      post forecast_budget_overrides_path, params: { forecast_budget_override: base_params(amount: "1000") }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid=forecast-budget-override-conflict]"
    assert_select "a[href=?]", edit_forecast_budget_override_path(existing)
  end

  # --- custom month canonicalization -----------------------------------------

  test "period_start_on canonicalizes to the family custom month start" do
    @family.update!(month_start_day: 15)

    post forecast_budget_overrides_path, params: {
      forecast_budget_override: base_params(period_start_on: Date.new(2026, 5, 1).to_s)
    }

    override = @family.forecast_budget_overrides.order(:created_at).last
    assert_equal Date.new(2026, 4, 15), override.period_start_on
  end

  # --- scenario coverage -----------------------------------------------------

  test "a scenario whose window does not cover the period is rejected with a 422" do
    scenario = @family.forecast_scenarios.create!(
      name: "Mid-month move",
      status: "active",
      starts_on: Date.current.beginning_of_month + 10.days,
      ends_on: Date.current.end_of_month
    )

    assert_no_difference "@family.forecast_budget_overrides.count" do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(forecast_scenario_id: scenario.id)
      }
    end

    assert_response :unprocessable_entity
  end

  # --- authorization ---------------------------------------------------------

  test "create ignores a family_id passed in params" do
    other_family = families(:empty)

    post forecast_budget_overrides_path, params: {
      forecast_budget_override: base_params(family_id: other_family.id)
    }

    override = @family.forecast_budget_overrides.order(:created_at).last
    assert_equal @family.id, override.family_id
  end

  test "a foreign category_id is rejected with a 422" do
    foreign_category = families(:empty).categories.create!(name: "Foreign", color: "#0d9488", lucide_icon: "tag")

    assert_no_difference "@family.forecast_budget_overrides.count" do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(category_id: foreign_category.id)
      }
    end

    assert_response :unprocessable_entity
  end

  test "a foreign scenario_id is rejected with a 422" do
    foreign_scenario = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active")

    assert_no_difference "@family.forecast_budget_overrides.count" do
      post forecast_budget_overrides_path, params: {
        forecast_budget_override: base_params(forecast_scenario_id: foreign_scenario.id)
      }
    end

    assert_response :unprocessable_entity
  end

  test "edit on another family's override is denied with a 404" do
    foreign = families(:empty).forecast_budget_overrides.create!(
      period_start_on: Date.current.beginning_of_month,
      override_type: "expected_income",
      amount: 5000,
      currency: "USD",
      status: "active"
    )

    get edit_forecast_budget_override_path(foreign)

    assert_response :not_found
  end

  test "update on another family's override is denied with a 404" do
    foreign = families(:empty).forecast_budget_overrides.create!(
      period_start_on: Date.current.beginning_of_month,
      override_type: "expected_income",
      amount: 5000,
      currency: "USD",
      status: "active"
    )

    patch forecast_budget_override_path(foreign), params: { forecast_budget_override: { amount: "1" } }

    assert_response :not_found
    assert_equal 5000, foreign.reload.amount.to_i
  end

  test "destroy on another family's override is denied with a 404" do
    foreign = families(:empty).forecast_budget_overrides.create!(
      period_start_on: Date.current.beginning_of_month,
      override_type: "expected_income",
      amount: 5000,
      currency: "USD",
      status: "active"
    )

    assert_no_difference "ForecastBudgetOverride.count" do
      delete forecast_budget_override_path(foreign)
    end

    assert_response :not_found
  end

  # --- update / destroy happy paths ------------------------------------------

  test "update changes the amount on the current family's override" do
    override = @family.forecast_budget_overrides.create!(base_params)

    patch forecast_budget_override_path(override), params: {
      forecast_budget_override: base_params(amount: "1234")
    }

    assert_response :redirect
    assert_equal 1234, override.reload.amount.to_i
  end

  test "destroy removes the current family's override" do
    override = @family.forecast_budget_overrides.create!(base_params)

    assert_difference "@family.forecast_budget_overrides.count", -1 do
      delete forecast_budget_override_path(override)
    end

    assert_response :redirect
  end
end
