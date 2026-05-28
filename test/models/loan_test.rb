require "test_helper"

class LoanTest < ActiveSupport::TestCase
  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  test "rejects invalid financial terms" do
    loan = Loan.new(
      initial_balance: -1,
      interest_rate: -0.1,
      term_months: 0,
      rate_type: "promotional"
    )

    assert_not loan.valid?
    assert_includes loan.errors[:initial_balance], "must be greater than or equal to 0"
    assert_includes loan.errors[:interest_rate], "must be greater than or equal to 0"
    assert_includes loan.errors[:term_months], "must be greater than 0"
    assert_includes loan.errors[:rate_type], "is not included in the list"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_equal 2245, loan_account.loan.monthly_payment.amount
  end

  test "original balance prefers stored initial balance over current valuation" do
    loan_account = Account.create!(
      family: families(:dylan_family),
      name: "Student Loan",
      balance: 45_000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "student",
        initial_balance: 48_000
      )
    )
    loan_account.entries.create!(
      date: Date.current,
      name: "Manual principal update",
      amount: 45_000,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )

    assert_equal 48_000, loan_account.loan.original_balance.amount
  end
end
