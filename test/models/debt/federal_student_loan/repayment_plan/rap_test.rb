require "test_helper"

class Debt::FederalStudentLoan::RepaymentPlan::RapTest < ActiveSupport::TestCase
  test "is unavailable without an explicit versioned rule set" do
    projection = Debt::FederalStudentLoan::RepaymentPlan::Rap.new(
      principal: 10_000.to_d,
      accrued_interest: 0.to_d,
      annual_rate: 6.to_d,
      annual_income: 65_000.to_d,
      dependent_count: 0,
      rules: nil
    ).project

    assert_not projection.available?
    assert_equal "rap_estimated_2026", projection.plan_code
    assert_match(/versioned RAP rules/, projection.warnings.join)
  end
end
