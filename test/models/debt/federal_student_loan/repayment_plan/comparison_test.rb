require "test_helper"

class Debt::FederalStudentLoan::RepaymentPlan::ComparisonTest < ActiveSupport::TestCase
  test "returns projections for selected plans without mutating records" do
    profile_record = DebtProfile.create!(account: accounts(:loan))
    profile_record.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "in_school",
      principal_balance: "10000",
      accrued_interest_balance: "500",
      weighted_average_rate: "6",
      repayment_assumptions: {
        "annual_income" => "65000",
        "family_size" => 1,
        "dependent_count" => 0,
        "state" => "US",
        "poverty_guideline" => "15650",
        "new_ibr_borrower" => true,
        "selected_plan_codes" => [ "standard_10_year", "ibr" ]
      }
    )
    profile_record.save!
    profile_record.debt_rate_periods.create!(rate_type: "fixed", annual_rate: 6, starts_on: Date.current, source: "manual")
    original_extra = profile_record.reload.extra.deep_dup
    original_updated_at = profile_record.updated_at

    assert_no_difference -> { Entry.count } do
      assert_no_difference -> { DebtEvent.count } do
        assert_no_difference -> { DebtObligation.count } do
          assert_no_difference -> { DebtPaymentAllocation.count } do
            @comparison = Debt::FederalStudentLoan::RepaymentPlan::Comparison.new(profile_record).call
          end
        end
      end
    end

    assert_equal [ "standard_10_year", "ibr" ], @comparison.map(&:plan_code)
    assert_equal original_extra, profile_record.reload.extra
    assert_equal original_updated_at.to_i, profile_record.updated_at.to_i
  end

  test "returns unavailable projection for tiered standard until versioned rules exist" do
    profile_record = DebtProfile.create!(account: accounts(:loan))
    profile_record.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "repayment",
      principal_balance: "10000",
      accrued_interest_balance: "0",
      repayment_assumptions: {
        "selected_plan_codes" => [ "tiered_standard_estimated_2026" ]
      }
    )
    profile_record.save!

    projection = Debt::FederalStudentLoan::RepaymentPlan::Comparison.new(profile_record).call.first

    assert_equal "tiered_standard_estimated_2026", projection.plan_code
    assert_not projection.available?
    assert_match(/Tiered Standard/, projection.warnings.join)
  end
end
