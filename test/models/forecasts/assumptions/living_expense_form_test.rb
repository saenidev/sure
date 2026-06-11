# frozen_string_literal: true

require "test_helper"

# Tests for the Forecast V2 LivingExpenseForm typed form object. living_expense
# is backend-derived in the MVP (no interactive editor yet) but the bootstrap
# path may save/validate it, so the form + params contract still exist (spec
# "Form Objects", "Assumption Params Contracts"). Same contract as SalaryForm.
class Forecasts::Assumptions::LivingExpenseFormTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @plan = @family.forecast_plans.create!(
      name: "Plan",
      status: :active,
      horizon_start_on: Date.new(2026, 1, 1),
      horizon_end_on: Date.new(2029, 1, 1),
      reporting_currency: "USD"
    )
    @category = categories(:food_and_drink)
  end

  def valid_input(overrides = {})
    {
      "name" => "Living expenses",
      "amount" => "4200",
      "currency" => "USD",
      "frequency" => "monthly",
      "category_ids" => [ @category.id ],
      "inflation_policy" => "fixed_rate",
      "inflation_rate" => "2.0",
      "actualization_policy" => "replace",
      "starts_on" => "2026-01-01",
      "ends_on" => "2028-12-31"
    }.merge(overrides)
  end

  def build_form(input: valid_input, assumption: nil)
    Forecasts::Assumptions::LivingExpenseForm.new(
      family: @family, plan: @plan, params: input, assumption: assumption
    )
  end

  test "valid input produces typed params + normalized attributes" do
    form = build_form

    assert form.valid?, -> { form.errors.inspect }
    params = form.params_object
    assert_instance_of Forecasts::Assumptions::LivingExpenseParams, params
    assert_equal BigDecimal("4200"), params.amount
    assert_equal [ @category.id ], params.category_ids
    assert_equal "replace", params.actualization_policy

    attrs = form.assumption_attributes
    assert_equal "living_expense", attrs[:kind]
    assert_equal BigDecimal("4200"), attrs[:amount]
    assert_equal [ @category.id ], attrs[:params]["category_ids"]
  end

  test "missing required fields emit blank codes" do
    form = build_form(input: valid_input("amount" => "", "actualization_policy" => nil))

    assert_not form.valid?
    assert_includes form.error_codes_for(:amount), "blank"
    assert_includes form.error_codes_for(:actualization_policy), "blank"
  end

  test "category from another family emits not_permitted" do
    other_family = families(:empty)
    foreign_category = other_family.categories.create!(name: "Theirs")

    form = build_form(input: valid_input("category_ids" => [ foreign_category.id ]))

    assert_not form.valid?
    assert_includes form.error_codes_for(:category_ids), "not_permitted"
  end

  test "stale lock_version emits stale_version" do
    assumption = @plan.forecast_assumptions.create!(
      family: @family, kind: "living_expense", name: "Existing",
      amount: 100, currency: "USD", status: :active
    )
    assumption.update!(name: "Bumped")

    form = build_form(
      input: valid_input("expected_lock_version" => assumption.lock_version - 1),
      assumption: assumption
    )

    assert_not form.valid?
    assert_includes form.error_codes_for(:base), "stale_version"
  end

  test "does not persist" do
    assert_no_difference -> { Forecasts::Assumption.count } do
      assert build_form.valid?
    end
  end
end
