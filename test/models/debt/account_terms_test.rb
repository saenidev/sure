require "test_helper"

class Debt::AccountTermsTest < ActiveSupport::TestCase
  setup do
    @loan_account = accounts(:loan)
    @credit_card_account = accounts(:credit_card)
  end

  test "uses current rate period before account defaults" do
    profile = DebtProfile.create!(account: @loan_account, rate_type: "fixed")
    DebtRatePeriod.create!(
      debt_profile: profile,
      rate_type: "promotional",
      annual_rate: 1.99,
      starts_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 12, 31),
      priority: 10
    )

    terms = Debt::AccountTerms.new(@loan_account, as_of: Date.new(2026, 5, 1)).resolve

    assert terms.accrual_ready?
    assert_equal "promotional", terms.rate_type
    assert_equal BigDecimal("1.99"), terms.annual_rate
    assert_equal "rate_period", terms.source
  end

  test "uses loan defaults when no current rate period exists" do
    DebtProfile.create!(account: @loan_account)

    terms = Debt::AccountTerms.new(@loan_account, as_of: Date.new(2026, 5, 1)).resolve

    assert terms.accrual_ready?
    assert_equal "fixed", terms.rate_type
    assert_equal BigDecimal("3.5"), terms.annual_rate
    assert_equal @loan_account.loan.monthly_payment.amount, terms.monthly_payment
    assert_equal @loan_account.balance, terms.opening_balance
    assert_equal "account", terms.source
  end

  test "uses credit card APR and minimum payment defaults" do
    DebtProfile.create!(account: @credit_card_account)

    terms = Debt::AccountTerms.new(@credit_card_account, as_of: Date.new(2026, 5, 1)).resolve

    assert terms.accrual_ready?
    assert_equal "variable", terms.rate_type
    assert_equal BigDecimal("18.99"), terms.annual_rate
    assert_equal BigDecimal("100.0"), terms.monthly_payment
  end

  test "reports missing annual rate" do
    other_liability = accounts(:other_liability)
    DebtProfile.create!(account: other_liability)

    terms = Debt::AccountTerms.new(other_liability, as_of: Date.new(2026, 5, 1)).resolve

    assert_not terms.accrual_ready?
    assert_includes terms.missing_fields, :annual_rate
  end
end
