require "test_helper"

class Debt::FederalStudentLoan::RepaymentPlan::StandardTest < ActiveSupport::TestCase
  test "projects ten year fixed payment without charging interest on accrued interest" do
    projection = Debt::FederalStudentLoan::RepaymentPlan::Standard.new(
      principal: 10_000.to_d,
      accrued_interest: 500.to_d,
      annual_rate: 6.to_d,
      months: 120
    ).project

    assert_equal "standard_10_year", projection.plan_code
    assert_equal 120, projection.month_count
    assert projection.first_payment_amount.positive?
    assert_in_delta BigDecimal("50.0"), projection.schedule.first.interest_accrued, BigDecimal("0.01")
    assert_equal BigDecimal("0.0"), projection.schedule.first.principal_paid
    assert_equal projection.first_payment_amount, projection.schedule.first.interest_paid
    assert_equal BigDecimal("0.0"), projection.forgiven_amount
  end
end
