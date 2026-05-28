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

  test "is unavailable when rules do not cover the supplied income" do
    projection = Debt::FederalStudentLoan::RepaymentPlan::Rap.new(
      principal: 10_000.to_d,
      accrued_interest: 0.to_d,
      annual_rate: 6.to_d,
      annual_income: 65_000.to_d,
      dependent_count: 0,
      rules: {
        "version" => "draft",
        "forgiveness_months" => 240,
        "brackets" => [],
        "dependent_monthly_discount" => 50,
        "minimum_monthly_payment" => 10
      }
    ).project

    assert_not projection.available?
    assert_match(/do not cover/, projection.warnings.join)
  end

  test "is unavailable when rules are incomplete" do
    projection = Debt::FederalStudentLoan::RepaymentPlan::Rap.new(
      principal: 10_000.to_d,
      accrued_interest: 0.to_d,
      annual_rate: 6.to_d,
      annual_income: 65_000.to_d,
      dependent_count: 0,
      rules: {
        "version" => "draft",
        "forgiveness_months" => 0,
        "brackets" => [ "malformed" ],
        "dependent_monthly_discount" => 50,
        "minimum_monthly_payment" => 10
      }
    ).project

    assert_not projection.available?
    assert_match(/incomplete/, projection.warnings.join)
  end

  test "is unavailable when rules contain nonnumeric values" do
    projection = Debt::FederalStudentLoan::RepaymentPlan::Rap.new(
      principal: 10_000.to_d,
      accrued_interest: 0.to_d,
      annual_rate: 6.to_d,
      annual_income: 65_000.to_d,
      dependent_count: 0,
      rules: {
        "version" => "draft",
        "forgiveness_months" => 240,
        "brackets" => [
          { "min_income" => "not-a-number", "annual_percent" => "8" }
        ],
        "dependent_monthly_discount" => 50,
        "minimum_monthly_payment" => 10
      }
    ).project

    assert_not projection.available?
    assert_match(/incomplete/, projection.warnings.join)
  end
end
