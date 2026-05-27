require "test_helper"

class Debt::FederalStudentLoan::CapitalizationServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:loan)
    @profile = DebtProfile.create!(account: @account)
    @profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "repayment",
      principal_balance: "10000",
      accrued_interest_balance: "500",
      capitalized_interest_total: "0"
    )
    @profile.save!
  end

  test "capitalizes accrued interest without changing account balance" do
    original_balance = @account.balance

    event = Debt::FederalStudentLoan::CapitalizationService.new(
      account: @account,
      as_of: Date.new(2026, 11, 1),
      reason: "entered_repayment"
    ).call

    assert_equal "interest_capitalization", event.event_type
    assert_equal "posted", event.status
    assert_nil event.entry
    assert_equal BigDecimal("500.0"), event.amount
    assert_equal original_balance, @account.reload.balance
    assert_equal BigDecimal("10500.0"), @profile.reload.federal_student_loan.principal_balance
    assert_equal BigDecimal("0.0"), @profile.federal_student_loan.accrued_interest_balance
    assert_equal BigDecimal("500.0"), @profile.federal_student_loan.capitalized_interest_total
  end

  test "capitalization is idempotent for the same reason and date" do
    first = Debt::FederalStudentLoan::CapitalizationService.new(account: @account, as_of: Date.new(2026, 11, 1), reason: "entered_repayment").call
    second = Debt::FederalStudentLoan::CapitalizationService.new(account: @account, as_of: Date.new(2026, 11, 1), reason: "entered_repayment").call

    assert_equal first, second
    assert_equal 1, @account.debt_events.where(event_type: "interest_capitalization").count
  end

  test "capitalization changes the future federal interest basis" do
    Debt::FederalStudentLoan::CapitalizationService.new(
      account: @account,
      as_of: Date.new(2026, 11, 1),
      reason: "entered_repayment"
    ).call

    policy = Debt::FederalStudentLoan::InterestPolicy.new(@profile.reload)

    assert_equal BigDecimal("10500.0"), policy.interest_basis_amount(account_balance: @account.balance)
  end

  test "capitalization rolls back event and federal balances on profile save failure" do
    DebtProfile.any_instance.stubs(:save!).raises(StandardError, "forced failure")

    assert_raises(StandardError) do
      Debt::FederalStudentLoan::CapitalizationService.new(
        account: @account,
        as_of: Date.new(2026, 11, 1),
        reason: "entered_repayment"
      ).call
    end

    assert_equal 0, @account.debt_events.where(event_type: "interest_capitalization").count
    assert_equal BigDecimal("10000.0"), @profile.reload.federal_student_loan.principal_balance
    assert_equal BigDecimal("500.0"), @profile.federal_student_loan.accrued_interest_balance
  end
end
