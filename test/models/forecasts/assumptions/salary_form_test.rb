# frozen_string_literal: true

require "test_helper"

# Tests for the Forecast V2 SalaryForm typed form object (spec "Form Objects",
# "Form object rules", "Assumption Params Contracts").
#
# The form owns input coercion, field-level + cross-field validation, and
# account/category permission checks (all family-scoped). On success it returns a
# typed SalaryParams value object plus the normalized top-level assumption
# attributes (kind, name, starts_on/ends_on or milestone refs, currency, amount).
# It NEVER persists — controllers/services own transactions + version increments.
# Errors use stable error codes mapped to localized field/summary copy.
class Forecasts::Assumptions::SalaryFormTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @plan = @family.forecast_plans.create!(
      name: "Plan",
      status: :active,
      horizon_start_on: Date.new(2026, 1, 1),
      horizon_end_on: Date.new(2029, 1, 1),
      reporting_currency: "USD"
    )
    @cash_account = accounts(:depository)
  end

  def valid_input(overrides = {})
    {
      "name" => "Primary salary",
      "amount" => "150000",
      "currency" => "USD",
      "person_key" => "jun",
      "gross_or_net" => "net",
      "frequency" => "annual",
      "growth_policy" => "fixed_rate",
      "growth_rate" => "3.0",
      "starts_on" => "2026-01-01",
      "ends_on" => "2028-12-31"
    }.merge(overrides)
  end

  def build_form(input: valid_input, assumption: nil)
    Forecasts::Assumptions::SalaryForm.new(
      family: @family,
      plan: @plan,
      params: input,
      assumption: assumption
    )
  end

  # --- valid input ----------------------------------------------------------

  test "valid input is valid and exposes typed params + normalized attributes" do
    form = build_form

    assert form.valid?, -> { form.errors.inspect }
    assert_empty form.errors

    params = form.params_object
    assert_instance_of Forecasts::Assumptions::SalaryParams, params
    assert_equal "jun", params.person_key
    assert_equal BigDecimal("150000"), params.amount
    assert_equal "net", params.gross_or_net
    assert_equal "USD", params.currency
    assert_equal "annual", params.frequency
    assert_equal "fixed_rate", params.growth_policy
    assert_equal BigDecimal("3.0"), params.growth_rate

    attrs = form.assumption_attributes
    assert_equal "salary", attrs[:kind]
    assert_equal "Primary salary", attrs[:name]
    assert_equal "USD", attrs[:currency]
    assert_equal BigDecimal("150000"), attrs[:amount]
    assert_equal Date.new(2026, 1, 1), attrs[:starts_on]
    assert_equal Date.new(2028, 12, 31), attrs[:ends_on]
    assert_nil attrs[:starts_at_milestone_id]
    assert_nil attrs[:ends_at_milestone_id]

    # The serialized params ride in assumption attributes as a string-keyed hash.
    assert_equal "jun", attrs[:params]["person_key"]
    assert_equal "150000.0", attrs[:params]["amount"]
  end

  test "coerces string amount and growth_rate to decimals" do
    form = build_form(input: valid_input("amount" => "  150000.50 ", "growth_rate" => "2.5"))

    assert form.valid?, -> { form.errors.inspect }
    assert_equal BigDecimal("150000.50"), form.params_object.amount
    assert_equal BigDecimal("2.5"), form.params_object.growth_rate
  end

  test "milestone anchors normalize to milestone refs instead of fixed dates" do
    retire = @plan.forecast_milestones.create!(
      name: "Retirement", kind: "retirement", date: Date.new(2028, 6, 1)
    )

    form = build_form(input: valid_input(
      "starts_on" => nil,
      "ends_on" => nil,
      "starts_at_milestone_id" => nil,
      "ends_at_milestone_id" => retire.id
    ))

    assert form.valid?, -> { form.errors.inspect }
    attrs = form.assumption_attributes
    assert_nil attrs[:ends_on]
    assert_equal retire.id, attrs[:ends_at_milestone_id]
  end

  # --- missing required fields ----------------------------------------------

  test "missing required fields emit stable blank error codes" do
    form = build_form(input: valid_input("amount" => "", "person_key" => nil))

    assert_not form.valid?
    assert_includes form.error_codes_for(:amount), "blank"
    assert_includes form.error_codes_for(:person_key), "blank"
  end

  test "missing name emits a blank error code" do
    form = build_form(input: valid_input("name" => "   "))

    assert_not form.valid?
    assert_includes form.error_codes_for(:name), "blank"
  end

  # --- field-level invalid values -------------------------------------------

  test "non-numeric amount emits not_a_number" do
    form = build_form(input: valid_input("amount" => "abc"))

    assert_not form.valid?
    assert_includes form.error_codes_for(:amount), "not_a_number"
  end

  test "negative amount emits not_positive" do
    form = build_form(input: valid_input("amount" => "-10"))

    assert_not form.valid?
    assert_includes form.error_codes_for(:amount), "not_positive"
  end

  test "unknown currency emits unknown_currency" do
    form = build_form(input: valid_input("currency" => "ZZZ"))

    assert_not form.valid?
    assert_includes form.error_codes_for(:currency), "unknown_currency"
  end

  test "invalid enum value emits inclusion error" do
    form = build_form(input: valid_input("gross_or_net" => "wrong"))

    assert_not form.valid?
    assert_includes form.error_codes_for(:gross_or_net), "inclusion"
  end

  # --- cross-field validation -----------------------------------------------

  test "ends_on before starts_on emits end_before_start" do
    form = build_form(input: valid_input("starts_on" => "2028-01-01", "ends_on" => "2026-01-01"))

    assert_not form.valid?
    assert_includes form.error_codes_for(:ends_on), "end_before_start"
  end

  test "fixed_rate growth without a growth_rate emits blank" do
    form = build_form(input: valid_input("growth_policy" => "fixed_rate", "growth_rate" => nil))

    assert_not form.valid?
    assert_includes form.error_codes_for(:growth_rate), "blank"
  end

  test "flat growth policy does not require a growth_rate" do
    form = build_form(input: valid_input("growth_policy" => "flat", "growth_rate" => nil))

    assert form.valid?, -> { form.errors.inspect }
    assert_nil form.params_object.growth_rate
  end

  # --- net_ratio (gross take-home) ------------------------------------------

  test "a gross salary persists its net_ratio so the engine reduces take-home" do
    form = build_form(input: valid_input("gross_or_net" => "gross", "net_ratio" => "0.7"))

    assert form.valid?, -> { form.errors.inspect }
    assert_equal BigDecimal("0.7"), form.params_object.net_ratio
    # And it serializes as a decimal string the engine can rehydrate.
    assert_equal "0.7", form.assumption_attributes[:params]["net_ratio"]
  end

  test "a net salary ignores net_ratio and omits it from persisted params" do
    # net == gross for a net salary, so a stray net_ratio must not leak through
    # and silently cut cash impact.
    form = build_form(input: valid_input("gross_or_net" => "net", "net_ratio" => "0.7"))

    assert form.valid?, -> { form.errors.inspect }
    assert_nil form.params_object.net_ratio
    assert_not form.assumption_attributes[:params].key?("net_ratio")
  end

  test "a gross salary without a net_ratio omits it (engine defaults net == gross)" do
    form = build_form(input: valid_input("gross_or_net" => "gross"))

    assert form.valid?, -> { form.errors.inspect }
    assert_nil form.params_object.net_ratio
    assert_not form.assumption_attributes[:params].key?("net_ratio")
  end

  test "non-numeric net_ratio emits not_a_number" do
    form = build_form(input: valid_input("gross_or_net" => "gross", "net_ratio" => "abc"))

    assert_not form.valid?
    assert_includes form.error_codes_for(:net_ratio), "not_a_number"
  end

  test "non-positive net_ratio emits not_positive" do
    form = build_form(input: valid_input("gross_or_net" => "gross", "net_ratio" => "0"))

    assert_not form.valid?
    assert_includes form.error_codes_for(:net_ratio), "not_positive"
  end

  # --- invalid references ----------------------------------------------------

  test "milestone reference from another plan emits invalid_reference" do
    other_plan = @family.forecast_plans.create!(
      name: "Other", status: :active,
      horizon_start_on: Date.new(2026, 1, 1), horizon_end_on: Date.new(2029, 1, 1),
      reporting_currency: "USD"
    )
    foreign_milestone = other_plan.forecast_milestones.create!(
      name: "Theirs", kind: "retirement", date: Date.new(2027, 1, 1)
    )

    form = build_form(input: valid_input("ends_on" => nil, "ends_at_milestone_id" => foreign_milestone.id))

    assert_not form.valid?
    assert_includes form.error_codes_for(:ends_at_milestone_id), "invalid_reference"
  end

  test "nonexistent milestone reference emits invalid_reference" do
    form = build_form(input: valid_input("ends_on" => nil, "ends_at_milestone_id" => SecureRandom.uuid))

    assert_not form.valid?
    assert_includes form.error_codes_for(:ends_at_milestone_id), "invalid_reference"
  end

  # --- account-permission failure -------------------------------------------

  test "cash_account from another family emits not_permitted" do
    other_family = families(:empty)
    foreign_account = other_family.accounts.create!(
      name: "Foreign checking",
      balance: 100,
      currency: "USD",
      accountable: Depository.new
    )

    form = build_form(input: valid_input("cash_account_id" => foreign_account.id))

    assert_not form.valid?
    assert_includes form.error_codes_for(:cash_account_id), "not_permitted"
  end

  test "cash_account belonging to the family is permitted" do
    form = build_form(input: valid_input("cash_account_id" => @cash_account.id))

    assert form.valid?, -> { form.errors.inspect }
    assert_equal @cash_account.id, form.params_object.cash_account_id
  end

  # --- stale lock / version conflict ----------------------------------------

  test "stale lock_version on an existing assumption emits stale_version" do
    assumption = @plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "Existing",
      amount: 100, currency: "USD", status: :active
    )
    # Bump the persisted lock_version so the submitted one is stale.
    assumption.update!(name: "Bumped")
    stale_version = assumption.lock_version - 1

    form = build_form(
      input: valid_input("expected_lock_version" => stale_version),
      assumption: assumption
    )

    assert_not form.valid?
    assert_includes form.error_codes_for(:base), "stale_version"
  end

  test "matching lock_version on an existing assumption is valid" do
    assumption = @plan.forecast_assumptions.create!(
      family: @family, kind: "salary", name: "Existing",
      amount: 100, currency: "USD", status: :active
    )

    form = build_form(
      input: valid_input("expected_lock_version" => assumption.lock_version),
      assumption: assumption
    )

    assert form.valid?, -> { form.errors.inspect }
  end

  # --- localized error-code mapping -----------------------------------------

  test "every emitted error code maps to localized copy" do
    # Construct one form that trips many distinct codes at once.
    form = build_form(input: valid_input(
      "amount" => "abc",
      "currency" => "ZZZ",
      "gross_or_net" => "wrong",
      "ends_on" => "2025-01-01",
      "ends_at_milestone_id" => SecureRandom.uuid
    ))
    form.valid?

    codes = form.errors.map { |error| error.options[:code] }.compact.uniq
    assert codes.any?, "expected the form to emit stable error codes"

    codes.each do |code|
      assert I18n.exists?("forecasts_v2.assumptions.errors.#{code}"),
        "missing localized copy for error code #{code.inspect}"
    end
  end

  # --- no persistence --------------------------------------------------------

  test "form does not persist and does not mutate the database" do
    assert_no_difference -> { Forecasts::Assumption.count } do
      form = build_form
      assert form.valid?
      form.params_object
      form.assumption_attributes
    end
  end
end
