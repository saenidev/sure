require "test_helper"

class Debt::FederalStudentLoan::ProfileTest < ActiveSupport::TestCase
  setup do
    @debt_profile = DebtProfile.create!(account: accounts(:loan))
  end

  test "defaults to disabled federal mode" do
    profile = Debt::FederalStudentLoan::Profile.new(@debt_profile)

    assert_not profile.enabled?
    assert_equal "0.0", profile.principal_balance.to_s
    assert_equal "0.0", profile.accrued_interest_balance.to_s
  end

  test "stores typed federal fields under debt profile extra" do
    profile = Debt::FederalStudentLoan::Profile.new(@debt_profile)
    profile.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "in_school",
      principal_balance: "12500.12",
      accrued_interest_balance: "315.45",
      capitalized_interest_total: "50.00",
      interest_bearing_principal_balance: "12500.12",
      servicer_balance_as_of: "2026-05-28",
      weighted_average_rate: "6.12",
      repayment_assumptions: {
        "annual_income" => "65000",
        "family_size" => 1,
        "dependent_count" => 0,
        "state" => "US",
        "poverty_guideline" => "15650",
        "policy_year" => 2026,
        "new_ibr_borrower" => true,
        "selected_plan_codes" => [ "standard_10_year", "ibr", "rap_estimated_2026" ]
      }
    )
    @debt_profile.save!

    reloaded = Debt::FederalStudentLoan::Profile.new(@debt_profile.reload)

    assert reloaded.enabled?
    assert_equal "unsubsidized", reloaded.subsidy_type
    assert_equal "in_school", reloaded.school_status
    assert_equal BigDecimal("12500.12"), reloaded.principal_balance
    assert_equal BigDecimal("315.45"), reloaded.accrued_interest_balance
    assert_equal BigDecimal("50.0"), reloaded.capitalized_interest_total
    assert_equal BigDecimal("12500.12"), reloaded.interest_bearing_principal_balance
    assert_equal Date.new(2026, 5, 28), reloaded.servicer_balance_as_of
    assert_equal BigDecimal("6.12"), reloaded.weighted_average_rate
    assert_equal [ "standard_10_year", "ibr", "rap_estimated_2026" ], reloaded.selected_plan_codes
  end

  test "rejects invalid federal student loan enum values" do
    profile = Debt::FederalStudentLoan::Profile.new(@debt_profile)
    profile.assign(enabled: true, subsidy_type: "private", school_status: "unknown")

    assert_not @debt_profile.valid?
    assert_includes @debt_profile.errors[:base], "Federal student loan subsidy type is invalid"
    assert_includes @debt_profile.errors[:base], "Federal student loan school status is invalid"
  end

  test "rejects invalid federal numeric and date fields without raising" do
    profile = Debt::FederalStudentLoan::Profile.new(@debt_profile)
    profile.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "repayment",
      principal_balance: "-1",
      accrued_interest_balance: "abc",
      servicer_balance_as_of: "not-a-date"
    )

    assert_not @debt_profile.valid?
    assert_includes @debt_profile.errors[:base], "Federal student loan principal balance must be nonnegative"
    assert_includes @debt_profile.errors[:base], "Federal student loan accrued interest balance must be a number"
    assert_includes @debt_profile.errors[:base], "Federal student loan servicer balance date is invalid"
  end

  test "mixed federal principal cap validation ignores nonnumeric fields already reported elsewhere" do
    profile = Debt::FederalStudentLoan::Profile.new(@debt_profile)
    profile.assign(
      enabled: true,
      subsidy_type: "mixed",
      school_status: "in_school",
      principal_balance: "not-a-number",
      accrued_interest_balance: "0",
      interest_bearing_principal_balance: "12000"
    )

    assert_not @debt_profile.valid?
    assert_includes @debt_profile.errors[:base], "Federal student loan principal balance must be a number"
  end

  test "mixed federal loans require interest-bearing principal for auto accrual" do
    @debt_profile.auto_accrual_enabled = true
    profile = Debt::FederalStudentLoan::Profile.new(@debt_profile)
    profile.assign(
      enabled: true,
      subsidy_type: "mixed",
      school_status: "in_school",
      principal_balance: "10000",
      accrued_interest_balance: "0"
    )

    assert_not @debt_profile.valid?
    assert_includes @debt_profile.errors[:base], "Federal mixed loans require interest-bearing principal for automatic accrual"
  end

  test "mixed federal loans reject interest-bearing principal above total principal" do
    profile = Debt::FederalStudentLoan::Profile.new(@debt_profile)
    profile.assign(
      enabled: true,
      subsidy_type: "mixed",
      school_status: "in_school",
      principal_balance: "10000",
      accrued_interest_balance: "0",
      interest_bearing_principal_balance: "12000"
    )

    assert_not @debt_profile.valid?
    assert_includes @debt_profile.errors[:base], "Federal student loan interest-bearing principal cannot exceed principal balance"
  end

  test "mixed federal loan principal payments reduce interest-bearing principal first" do
    profile = Debt::FederalStudentLoan::Profile.new(@debt_profile)
    profile.assign(
      enabled: true,
      subsidy_type: "mixed",
      school_status: "in_school",
      principal_balance: "10000",
      accrued_interest_balance: "300",
      interest_bearing_principal_balance: "4000"
    )
    @debt_profile.save!

    profile.apply_payment!(interest_amount: 300, principal_amount: 1000)
    @debt_profile.save!

    reloaded = @debt_profile.reload.federal_student_loan
    assert_equal BigDecimal("9000.0"), reloaded.principal_balance
    assert_equal BigDecimal("3000.0"), reloaded.interest_bearing_principal_balance
  end
end
