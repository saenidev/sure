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
end
