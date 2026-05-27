require "test_helper"

class Debt::FederalStudentLoan::RepaymentPlan::IbrTest < ActiveSupport::TestCase
  test "new borrowers use ten percent discretionary income and 240 months" do
    projection = Debt::FederalStudentLoan::RepaymentPlan::Ibr.new(
      principal: 10_000.to_d,
      accrued_interest: 0.to_d,
      annual_rate: 6.to_d,
      annual_income: 65_000.to_d,
      poverty_guideline: 15_650.to_d,
      new_borrower: true,
      standard_monthly_payment: 120.to_d
    ).project

    assert_equal "ibr", projection.plan_code
    assert_equal 240, projection.month_count
    assert_equal BigDecimal("120.0"), projection.first_payment_amount
  end

  test "old borrowers use fifteen percent discretionary income and 300 months" do
    projection = Debt::FederalStudentLoan::RepaymentPlan::Ibr.new(
      principal: 50_000.to_d,
      accrued_interest: 0.to_d,
      annual_rate: 6.to_d,
      annual_income: 65_000.to_d,
      poverty_guideline: 15_650.to_d,
      new_borrower: false,
      standard_monthly_payment: 600.to_d
    ).project

    assert_equal 300, projection.month_count
    assert_equal BigDecimal("519.06"), projection.first_payment_amount
  end

  test "low income can produce a zero dollar payment and forgiven balance" do
    projection = Debt::FederalStudentLoan::RepaymentPlan::Ibr.new(
      principal: 10_000.to_d,
      accrued_interest: 0.to_d,
      annual_rate: 6.to_d,
      annual_income: 10_000.to_d,
      poverty_guideline: 15_650.to_d,
      new_borrower: true,
      standard_monthly_payment: 120.to_d
    ).project

    assert_equal BigDecimal("0.0"), projection.first_payment_amount
    assert projection.forgiven_amount.positive?
  end
end
