# frozen_string_literal: true

require "test_helper"

# Tests for the Forecast V2 default plan builder. When a family opens /forecast
# with no active V2 plan, this application service idempotently creates exactly
# one active Forecasts::Plan and derives baseline assumptions with provenance:
# a salary assumption from recurring payroll deposits and a living_expense
# assumption from budgets (or spending averages). Each derived assumption records
# origin (source_derived), confidence, review_state (needs_review), source_refs,
# derived_at, and derivation_version. Reopening must not duplicate plans or
# assumptions (keyed by family + source record). It is family-scoped and never
# trusts a family_id from params. See spec "Default Plan Derivation",
# "Bootstrap Rules", "Source-To-Assumption Mapping", "Derivation Confidence".
class Forecasts::DefaultPlanBuilderTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    # The fixture budget (`budgets(:one)`) spans the current month; anchor as_of
    # inside it so it is the "current budget" the living_expense should prefer.
    @as_of = Date.current

    # A recurring payroll-like deposit: amount < 0 means an inflow (income) under
    # Sure's sign convention. Non-transfer, active.
    @payroll = @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "Acme Payroll",
      amount: -5_000,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: @as_of - 1.month,
      next_expected_date: @as_of + 1.month,
      status: "active",
      occurrence_count: 6
    )

    # The current budget the living_expense assumption should prefer.
    @budget = budgets(:one)
    @budget.update!(budgeted_spending: 3_200)
  end

  def build(as_of: @as_of)
    Forecasts::DefaultPlanBuilder.new(family: @family, as_of: as_of).build
  end

  test "first call creates exactly one active plan with salary and living_expense" do
    plan = nil
    assert_difference -> { Forecasts::Plan.where(family: @family).count }, 1 do
      assert_difference -> { Forecasts::Assumption.where(family: @family).count }, 2 do
        plan = build
      end
    end

    assert plan.persisted?
    assert plan.active?
    assert_equal @family.id, plan.family_id
    assert_equal "USD", plan.reporting_currency

    kinds = plan.forecast_assumptions.pluck(:kind).sort
    assert_equal %w[living_expense salary], kinds
  end

  test "default plan horizon is 3 years (36 months)" do
    plan = build

    assert_equal @as_of, plan.horizon_start_on
    assert_equal @as_of >> 36, plan.horizon_end_on
  end

  test "a recurring inflow on a liability account is never picked as the salary source" do
    # A credit-card payment is an inflow TO the liability account (e.g. a
    # "CAPITAL ONE PAYMENT") — a bill payment, not income. Even when it is the
    # largest recurring inflow it must never become the salary source.
    cc_payment = @family.recurring_transactions.create!(
      account: accounts(:credit_card),
      name: "CAPITAL ONE PAYMENT",
      amount: -8_000,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: @as_of - 1.month,
      next_expected_date: @as_of + 1.month,
      status: "active",
      occurrence_count: 6
    )

    plan = build
    salary = plan.forecast_assumptions.find_by(kind: "salary")

    assert_not_nil salary
    assert_not_equal cc_payment.id, salary.source_record_id
    assert_equal @payroll.id, salary.source_record_id
    assert_equal BigDecimal("5000"), salary.amount
  end

  test "with no depository recurring inflow the salary falls back to median monthly income" do
    @payroll.destroy!
    # The only recurring inflow is a credit-card bill payment, which must not
    # qualify; the derived salary amount comes from the income statement median.
    @family.recurring_transactions.create!(
      account: accounts(:credit_card),
      name: "CAPITAL ONE PAYMENT",
      amount: -11.99,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: @as_of - 1.month,
      next_expected_date: @as_of + 1.month,
      status: "active",
      occurrence_count: 6
    )
    IncomeStatement.any_instance.stubs(:median_income).returns(4_500)

    plan = build
    salary = plan.forecast_assumptions.find_by(kind: "salary")

    assert_not_nil salary
    assert_nil salary.source_record_type
    assert_nil salary.source_record_id
    assert_equal BigDecimal("4500"), salary.amount
    assert_equal "source_derived", salary.origin
    assert_equal "needs_review", salary.review_state
  end

  test "derives no salary when there is no qualifying inflow and median income is zero" do
    @payroll.destroy!
    IncomeStatement.any_instance.stubs(:median_income).returns(0)

    plan = build

    assert_nil plan.forecast_assumptions.find_by(kind: "salary")
  end

  test "derived assumptions store the complete editable params contract" do
    # The drawer forms validate the full params contract on every save; a
    # derived assumption missing required params (person_key, gross_or_net,
    # actualization_policy, ...) could never be edited.
    plan = build

    salary = plan.forecast_assumptions.find_by(kind: "salary")
    assert_equal "primary", salary.params["person_key"]
    assert_equal "net", salary.params["gross_or_net"]
    assert_equal "monthly", salary.params["frequency"]
    assert_equal "flat", salary.params["growth_policy"]
    assert_equal "USD", salary.params["currency"]

    living = plan.forecast_assumptions.find_by(kind: "living_expense")
    assert_equal "monthly", living.params["frequency"]
    assert_equal "flat", living.params["inflation_policy"]
    assert_equal "none", living.params["actualization_policy"]
    assert_equal "USD", living.params["currency"]
  end

  test "derived salary carries provenance keyed to the payroll source record" do
    plan = build
    salary = plan.forecast_assumptions.find_by(kind: "salary")

    assert_not_nil salary
    assert_equal "source_derived", salary.origin
    assert_equal "medium", salary.confidence
    assert_equal "needs_review", salary.review_state
    assert salary.derived_at.present?
    assert salary.derivation_version.present?

    assert_equal "RecurringTransaction", salary.source_record_type
    assert_equal @payroll.id, salary.source_record_id

    # source_refs traces back to the source record used to derive it.
    refs = salary.source_refs.deep_symbolize_keys
    assert_equal "RecurringTransaction", refs[:records].first[:type]
    assert_equal @payroll.id, refs[:records].first[:id]

    # Salary amount derives from the deposit magnitude (income is positive here).
    assert_equal BigDecimal("5000"), salary.amount
  end

  test "derived living_expense carries provenance keyed to the budget source record" do
    plan = build
    living = plan.forecast_assumptions.find_by(kind: "living_expense")

    assert_not_nil living
    assert_equal "source_derived", living.origin
    assert_equal "medium", living.confidence
    assert_equal "needs_review", living.review_state
    assert living.derived_at.present?
    assert living.derivation_version.present?

    assert_equal "Budget", living.source_record_type
    assert_equal @budget.id, living.source_record_id
    assert_equal BigDecimal("3200"), living.amount
  end

  test "second call is a no-op: no duplicate plans or assumptions" do
    first = build

    assert_no_difference -> { Forecasts::Plan.where(family: @family).count } do
      assert_no_difference -> { Forecasts::Assumption.where(family: @family).count } do
        second = build
        assert_equal first.id, second.id
      end
    end
  end

  test "reopening does not duplicate assumptions for the same source record" do
    build

    # Re-running must not create a second salary/living_expense for the same
    # source records, even though the plan already exists.
    assert_no_difference -> { Forecasts::Assumption.where(family: @family).count } do
      build
    end

    salaries = Forecasts::Assumption.where(family: @family, kind: "salary").count
    livings = Forecasts::Assumption.where(family: @family, kind: "living_expense").count
    assert_equal 1, salaries
    assert_equal 1, livings
  end

  test "falls back to spending average when no current budget exists" do
    @budget.destroy!

    # A recurring outflow (positive amount) becomes the spending-average source.
    rent = @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "Rent",
      amount: 2_000,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: @as_of - 1.month,
      next_expected_date: @as_of + 1.month,
      status: "active",
      occurrence_count: 6
    )

    plan = build
    living = plan.forecast_assumptions.find_by(kind: "living_expense")

    assert_not_nil living
    assert_equal "RecurringTransaction", living.source_record_type
    assert_equal rent.id, living.source_record_id
    assert_equal BigDecimal("2000"), living.amount
  end

  test "reopening after the living_expense source changes does not double-count" do
    # First load derives living_expense from the current budget.
    first = build
    living = first.forecast_assumptions.find_by(kind: "living_expense")
    assert_equal "Budget", living.source_record_type
    assert_equal @budget.id, living.source_record_id

    # The budget goes away and a recurring outflow becomes the only spending
    # source — a *different* source record than the original budget. Reopening
    # must NOT create a second living_expense (which would double-count spending);
    # the plan already carries a source-derived living_expense.
    @budget.destroy!
    @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "Rent",
      amount: 2_000,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: @as_of - 1.month,
      next_expected_date: @as_of + 1.month,
      status: "active",
      occurrence_count: 6
    )

    assert_no_difference -> { Forecasts::Assumption.where(family: @family, kind: "living_expense").count } do
      build
    end

    livings = Forecasts::Assumption.where(family: @family, kind: "living_expense")
    assert_equal 1, livings.count
    # The original budget-derived assumption is preserved untouched.
    assert_equal "Budget", livings.sole.source_record_type
    assert_equal @budget.id, livings.sole.source_record_id
  end

  test "is family-scoped: does not read or write another family's data" do
    other_family = families(:empty)

    Forecasts::DefaultPlanBuilder.new(family: other_family, as_of: @as_of).build

    # The other family has no income/spending sources, so it gets a plan but no
    # source-derived salary/living_expense (and never dylan's records).
    other_plan = Forecasts::Plan.where(family: other_family).sole
    assert_equal other_family.id, other_plan.family_id
    assert_empty other_plan.forecast_assumptions.where(source_record_id: [ @payroll.id, @budget.id ])
  end
end
