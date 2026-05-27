require "test_helper"

class Debt::FederalStudentLoan::InterestPolicyTest < ActiveSupport::TestCase
  setup do
    @profile_record = DebtProfile.create!(account: accounts(:loan))
    @profile = @profile_record.federal_student_loan
  end

  test "unsubsidized loans accrue while in school on principal only" do
    @profile.assign(enabled: true, subsidy_type: "unsubsidized", school_status: "in_school", principal_balance: "10000")

    policy = Debt::FederalStudentLoan::InterestPolicy.new(@profile_record)

    assert policy.accrues_interest?
    assert_equal BigDecimal("10000"), policy.interest_basis_amount(account_balance: 12000.to_d)
  end

  test "subsidized loans do not accrue while in school grace or deferment" do
    @profile.assign(enabled: true, subsidy_type: "subsidized", school_status: "in_school", principal_balance: "10000")
    assert_not Debt::FederalStudentLoan::InterestPolicy.new(@profile_record).accrues_interest?

    @profile.assign(school_status: "grace")
    assert_not Debt::FederalStudentLoan::InterestPolicy.new(@profile_record).accrues_interest?

    @profile.assign(school_status: "deferment")
    assert_not Debt::FederalStudentLoan::InterestPolicy.new(@profile_record).accrues_interest?
  end

  test "subsidized loans accrue in repayment and forbearance" do
    @profile.assign(enabled: true, subsidy_type: "subsidized", school_status: "repayment", principal_balance: "10000")
    assert Debt::FederalStudentLoan::InterestPolicy.new(@profile_record).accrues_interest?

    @profile.assign(school_status: "forbearance")
    assert Debt::FederalStudentLoan::InterestPolicy.new(@profile_record).accrues_interest?
  end

  test "mixed in-school loans require an explicit interest-bearing principal basis" do
    @profile.assign(enabled: true, subsidy_type: "mixed", school_status: "in_school", principal_balance: "10000")
    assert_not Debt::FederalStudentLoan::InterestPolicy.new(@profile_record).accrues_interest?

    @profile.assign(interest_bearing_principal_balance: "4000")
    policy = Debt::FederalStudentLoan::InterestPolicy.new(@profile_record)

    assert policy.accrues_interest?
    assert_equal BigDecimal("4000"), policy.interest_basis_amount(account_balance: 12000.to_d)
  end

  test "disabled federal mode falls back to account balance basis" do
    policy = Debt::FederalStudentLoan::InterestPolicy.new(@profile_record)

    assert policy.generic_debt_mode?
    assert_equal BigDecimal("12000"), policy.interest_basis_amount(account_balance: 12000.to_d)
  end
end
