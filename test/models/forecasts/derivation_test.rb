# frozen_string_literal: true

require "test_helper"

# Forecasts::Derivation — the pure, read-only proposal engine extracted from
# DefaultPlanBuilder. Covers: per-kind precedence-chain correctness, the FULL
# typed-params contract on proposals, existing:-based re-derive from the linked
# source, source_gone detection, fallback-basis re-run for source-record-less
# assumptions, and zero-skip (nil proposal).
class Forecasts::DerivationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @as_of = Date.current
    # The fixture budget spans the current month (see DefaultPlanBuilderTest);
    # give it a positive budgeted_spending so it is the preferred living source.
    @budget = budgets(:one)
    @budget.update!(budgeted_spending: 3_200)
  end

  # --- salary: precedence chain (no existing:) -----------------------------

  test "salary proposal derives from the largest qualifying recurring inflow with the full params contract" do
    payroll = create_payroll
    create_payroll(amount: -1_200, name: "Side gig")

    proposal = derivation.salary_proposal

    assert proposal.ok?
    assert proposal.needs_review?
    assert_equal "salary", proposal.kind
    assert_equal "Acme Payroll", proposal.name
    assert_equal BigDecimal("5000"), proposal.amount
    assert_equal "USD", proposal.currency
    assert_equal "medium", proposal.confidence
    assert_equal payroll, proposal.source_record
    assert_equal(
      { "records" => [ { "type" => "RecurringTransaction", "id" => payroll.id } ] },
      proposal.source_refs
    )

    params = proposal.params
    assert_equal "primary", params["person_key"]
    assert_equal "net", params["gross_or_net"]
    assert_equal "monthly", params["frequency"]
    assert_equal "flat", params["growth_policy"]
    assert_equal "5000.0", params["amount"]
    assert_equal payroll.account_id, params["cash_account_id"]
    assert_equal "USD", params["currency"]
    assert_nil params["start_anchor"]
    assert_nil params["end_anchor"]
  end

  test "salary proposal falls back to the income-statement median when no inflow qualifies" do
    IncomeStatement.any_instance.stubs(:median_income).returns(4_500)

    proposal = derivation.salary_proposal

    assert proposal.ok?
    assert_equal "Estimated income", proposal.name
    assert_equal BigDecimal("4500"), proposal.amount
    assert_equal "low", proposal.confidence
    assert_nil proposal.source_record
    assert_equal(
      { "records" => [], "basis" => "income_statement_median_income" },
      proposal.source_refs
    )
    assert_equal "4500.0", proposal.params["amount"]
    assert_nil proposal.params["cash_account_id"]
  end

  test "salary proposal is nil when there is no inflow and median income is zero" do
    IncomeStatement.any_instance.stubs(:median_income).returns(0)

    assert_nil derivation.salary_proposal
  end

  # --- salary: existing:-based re-derive ------------------------------------

  test "salary proposal with existing re-derives from that assumption's linked source" do
    payroll = create_payroll
    existing = derived_assumption("salary")
    payroll.update!(amount: -6_000)

    proposal = derivation.salary_proposal(existing: existing)

    assert proposal.ok?
    assert_equal BigDecimal("6000"), proposal.amount
    assert_equal payroll, proposal.source_record
    assert_equal "6000.0", proposal.params["amount"]
  end

  test "salary proposal with existing is source_gone when the linked record was deleted" do
    payroll = create_payroll
    existing = derived_assumption("salary")
    payroll.destroy!

    proposal = derivation.salary_proposal(existing: existing)

    assert proposal.source_gone?
    assert_equal :source_gone, proposal.status
    assert_equal "salary", proposal.kind
  end

  test "salary proposal with existing is source_gone when the linked record no longer qualifies" do
    payroll = create_payroll
    existing = derived_assumption("salary")
    # Sign flip: the recurring row is now an outflow, not income.
    payroll.update!(amount: 50)

    assert derivation.salary_proposal(existing: existing).source_gone?
  end

  test "salary proposal with a source-record-less existing re-runs the median fallback basis" do
    IncomeStatement.any_instance.stubs(:median_income).returns(4_500)
    existing = derived_assumption("salary")
    assert_nil existing.source_record_type

    IncomeStatement.any_instance.stubs(:median_income).returns(5_100)
    proposal = derivation.salary_proposal(existing: existing)

    assert proposal.ok?
    assert_equal BigDecimal("5100"), proposal.amount
    assert_equal "low", proposal.confidence
    assert_equal "income_statement_median_income", proposal.source_refs["basis"]
  end

  # --- living expense: precedence chain (no existing:) ----------------------

  test "living expense proposal prefers the current budget and carries the full params contract" do
    proposal = derivation.living_expense_proposal

    assert proposal.ok?
    assert proposal.needs_review?
    assert_equal "living_expense", proposal.kind
    assert_equal "Living expenses", proposal.name
    assert_equal BigDecimal("3200"), proposal.amount
    assert_equal @budget.currency, proposal.currency
    assert_equal "medium", proposal.confidence
    assert_equal @budget, proposal.source_record

    params = proposal.params
    assert_equal "budget", params["basis"]
    assert_equal "monthly", params["frequency"]
    assert_equal "flat", params["inflation_policy"]
    assert_equal "none", params["actualization_policy"]
    assert_equal [], params["category_ids"]
    assert_equal "3200.0", params["amount"]
  end

  test "living expense proposal falls back to the largest recurring outflow when no budget is usable" do
    @budget.update!(budgeted_spending: 0)
    spend = @family.recurring_transactions.create!(
      account: accounts(:depository),
      name: "Rent",
      amount: 1_800,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: @as_of - 1.month,
      next_expected_date: @as_of + 1.month,
      status: "active",
      occurrence_count: 6
    )

    proposal = derivation.living_expense_proposal

    assert_equal BigDecimal("1800"), proposal.amount
    assert_equal "Rent", proposal.name
    assert_equal spend, proposal.source_record
    assert_equal "recurring_average", proposal.params["basis"]
  end

  test "living expense proposal falls back to the income-statement median expense last" do
    @family.budgets.destroy_all
    @family.recurring_transactions.where("amount > 0").destroy_all
    IncomeStatement.any_instance.stubs(:median_expense).returns(2_750)

    proposal = derivation.living_expense_proposal

    assert_equal "Estimated living expenses", proposal.name
    assert_equal BigDecimal("2750"), proposal.amount
    assert_equal "low", proposal.confidence
    assert_nil proposal.source_record
    assert_equal "income_statement_median_expense", proposal.source_refs["basis"]
    assert_equal "median_expense", proposal.params["basis"]
  end

  test "living expense proposal is nil when there is no spending source and median expense is zero" do
    @family.budgets.destroy_all
    @family.recurring_transactions.where("amount > 0").destroy_all
    IncomeStatement.any_instance.stubs(:median_expense).returns(0)

    assert_nil derivation.living_expense_proposal
  end

  # --- living expense: existing:-based re-derive -----------------------------

  test "living expense proposal with existing re-derives from the linked budget" do
    existing = derived_assumption("living_expense")
    @budget.update!(budgeted_spending: 3_900)

    proposal = derivation.living_expense_proposal(existing: existing)

    assert proposal.ok?
    assert_equal BigDecimal("3900"), proposal.amount
    assert_equal @budget, proposal.source_record
    assert_equal "budget", proposal.params["basis"]
  end

  test "living expense proposal with existing is source_gone when the budget was deleted" do
    existing = derived_assumption("living_expense")
    @budget.destroy!

    proposal = derivation.living_expense_proposal(existing: existing)

    assert proposal.source_gone?
    assert_equal "living_expense", proposal.kind
  end

  test "living expense proposal with existing is source_gone when the budget dropped to zero spend" do
    existing = derived_assumption("living_expense")
    @budget.update!(budgeted_spending: 0)

    assert derivation.living_expense_proposal(existing: existing).source_gone?
  end

  test "living expense proposal with a source-record-less existing re-runs the median fallback basis" do
    @family.budgets.destroy_all
    @family.recurring_transactions.where("amount > 0").destroy_all
    IncomeStatement.any_instance.stubs(:median_expense).returns(2_750)
    existing = derived_assumption("living_expense")
    assert_nil existing.source_record_type

    IncomeStatement.any_instance.stubs(:median_expense).returns(3_050)
    proposal = derivation.living_expense_proposal(existing: existing)

    assert proposal.ok?
    assert_equal BigDecimal("3050"), proposal.amount
    assert_equal "median_expense", proposal.params["basis"]
  end

  private
    def derivation
      Forecasts::Derivation.new(family: @family, as_of: @as_of)
    end

    def create_payroll(amount: -5_000, name: "Acme Payroll")
      @family.recurring_transactions.create!(
        account: accounts(:depository),
        name: name,
        amount: amount,
        currency: "USD",
        expected_day_of_month: 1,
        last_occurrence_date: @as_of - 1.month,
        next_expected_date: @as_of + 1.month,
        status: "active",
        occurrence_count: 6
      )
    end

    # Seeds via the (refactored) builder so existing:-based tests run against a
    # real derived row — proving Derivation and DefaultPlanBuilder agree.
    def derived_assumption(kind)
      plan = Forecasts::DefaultPlanBuilder.new(family: @family, as_of: @as_of).build
      plan.forecast_assumptions.where(kind: kind, origin: "source_derived").sole
    end
end
