require "test_helper"

class DebtProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
  end

  test "edit renders for manual debt account" do
    get edit_account_debt_profile_path(@account)

    assert_response :success
    assert_select "form[action='#{account_debt_profile_path(@account)}']"
    assert_select "input[name='_method'][value='patch']"
    assert_select "select[name='debt_profile[accrual_cadence]']"
    assert_select "select[name='debt_profile[compounding_cadence]']", count: 0
  end

  test "update creates profile for manual debt account" do
    assert_difference -> { DebtProfile.count }, 1 do
      patch account_debt_profile_path(@account), params: {
        debt_profile: {
          status: "active",
          auto_accrual_enabled: "1",
          auto_payment_allocation_enabled: "1",
          rate_type: "fixed",
          annual_rate: "6.25",
          accrual_cadence: "daily",
          compounding_cadence: "monthly",
          minimum_payment_amount: "125.50",
          minimum_payment_percent: "2.5",
          payment_due_day: "15",
          statement_closing_day: "3",
          grace_period_days: "21"
        }
      }
    end

    profile = @account.reload.debt_profile
    assert profile.auto_accrual_enabled?
    assert profile.auto_payment_allocation_enabled?
    assert_equal "fixed", profile.rate_type
    assert_equal BigDecimal("6.25"), profile.debt_rate_periods.first.annual_rate
    assert_equal "daily", profile.accrual_cadence
    assert_equal "monthly", profile.compounding_cadence
    assert_equal BigDecimal("125.50"), profile.minimum_payment_amount
    assert_equal BigDecimal("2.5"), profile.minimum_payment_percent
    assert_equal 15, profile.payment_due_day
    assert_redirected_to account_path(@account, tab: "overview")
  end

  test "update creates rate period for other liability accrual terms" do
    other_liability = accounts(:other_liability)

    patch account_debt_profile_path(other_liability), params: {
      debt_profile: {
        status: "active",
        auto_accrual_enabled: "1",
        rate_type: "variable",
        annual_rate: "9.5"
      }
    }

    profile = other_liability.reload.debt_profile
    terms = Debt::AccountTerms.new(other_liability).resolve

    assert_equal BigDecimal("9.5"), profile.debt_rate_periods.first.annual_rate
    assert terms.accrual_ready?
    assert_equal BigDecimal("9.5"), terms.annual_rate
  end

  test "edit renders federal student loan fields" do
    get edit_account_debt_profile_path(@account)

    assert_response :success
    assert_select "input[name='debt_profile[federal_student_loan][enabled]']"
    assert_select "select[name='debt_profile[federal_student_loan][subsidy_type]']"
    assert_select "select[name='debt_profile[federal_student_loan][school_status]']"
    assert_select "input[name='debt_profile[federal_student_loan][principal_balance]']"
    assert_select "input[name='debt_profile[federal_student_loan][accrued_interest_balance]']"
    assert_select "input[name='debt_profile[federal_student_loan][repayment_assumptions][annual_income]']"
    assert_select "input[name='debt_profile[federal_student_loan][repayment_assumptions][poverty_guideline]']"
  end

  test "update saves federal student loan settings" do
    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        federal_student_loan: {
          enabled: "1",
          subsidy_type: "unsubsidized",
          school_status: "in_school",
          principal_balance: "12500",
          accrued_interest_balance: "315.42",
          interest_bearing_principal_balance: "12500",
          weighted_average_rate: "6.12",
          servicer_balance_as_of: "2026-05-28",
          repayment_assumptions: {
            annual_income: "65000",
            poverty_guideline: "15650",
            dependent_count: "0",
            new_ibr_borrower: "1"
          }
        }
      }
    }

    assert_redirected_to account_path(@account, tab: "overview")
    federal = @account.reload.debt_profile.federal_student_loan
    assert federal.enabled?
    assert_equal "unsubsidized", federal.subsidy_type
    assert_equal BigDecimal("12500.0"), federal.principal_balance
    assert_equal "65000", federal.repayment_assumptions["annual_income"]
    assert_equal "15650", federal.repayment_assumptions["poverty_guideline"]
    assert_equal "1", federal.repayment_assumptions["new_ibr_borrower"]
    assert_equal BigDecimal("6.12"), @account.debt_profile.debt_rate_periods.first.annual_rate
  end

  test "update does not create profile for connected debt account" do
    AccountProvider.create!(account: @account, provider: plaid_accounts(:one))

    assert_no_difference -> { DebtProfile.count } do
      patch account_debt_profile_path(@account), params: {
        debt_profile: { status: "active", auto_accrual_enabled: "1" }
      }
    end

    assert_redirected_to account_path(@account)
    assert_equal I18n.t("debt_profiles.unsupported"), flash[:alert]
  end

  test "account overview renders for credit cards and other liabilities" do
    get account_path(accounts(:credit_card), tab: "overview")
    assert_response :success

    get account_path(accounts(:other_liability), tab: "overview")
    assert_response :success
  end

  test "account overview renders federal balances and repayment scenarios" do
    profile = DebtProfile.create!(account: @account, status: "active")
    profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "repayment",
      principal_balance: "10000",
      accrued_interest_balance: "500",
      repayment_assumptions: {
        "annual_income" => "65000",
        "poverty_guideline" => "15650",
        "selected_plan_codes" => [ "standard_10_year", "tiered_standard_estimated_2026" ]
      }
    )
    profile.save!
    profile.debt_rate_periods.create!(rate_type: "fixed", annual_rate: 6, starts_on: Date.current, source: "manual")

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "*", text: I18n.t("debt_profiles.overview.principal_balance")
    assert_select "*", text: I18n.t("debt_profiles.overview.accrued_interest")
    assert_select "*", text: I18n.t("debt_profiles.overview.repayment_scenarios")
    assert_select "*", text: "Standard"
    assert_select "*", text: "Tiered Standard estimate"
  end
end
