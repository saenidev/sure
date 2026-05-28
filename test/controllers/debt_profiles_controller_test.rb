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
    assert_select "input[type='checkbox'][name='debt_profile[federal_student_loan][repayment_assumptions][selected_plan_codes][]'][value='standard_10_year']"
    assert_select "input[type='checkbox'][name='debt_profile[federal_student_loan][repayment_assumptions][selected_plan_codes][]'][value='ibr']"
    assert_select "input[type='checkbox'][name='debt_profile[federal_student_loan][repayment_assumptions][selected_plan_codes][]'][value='rap_estimated_2026']"
    assert_select "input[type='checkbox'][name='debt_profile[federal_student_loan][repayment_assumptions][selected_plan_codes][]'][value='tiered_standard_estimated_2026']"
  end

  test "edit hides federal student loan fields for non loan debt accounts" do
    get edit_account_debt_profile_path(accounts(:credit_card))

    assert_response :success
    assert_select "input[name='debt_profile[federal_student_loan][enabled]']", count: 0
    assert_select "input[name='debt_profile[federal_student_loan][principal_balance]']", count: 0
  end

  test "update ignores federal student loan params for non loan debt accounts" do
    credit_card = accounts(:credit_card)

    patch account_debt_profile_path(credit_card), params: {
      debt_profile: {
        status: "active",
        federal_student_loan: {
          enabled: "0",
          principal_balance: "999"
        }
      }
    }

    assert_redirected_to account_path(credit_card, tab: "overview")
    assert_empty credit_card.reload.debt_profile.extra
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

  test "update preserves federal repayment assumptions omitted by the form" do
    profile = DebtProfile.create!(account: @account, status: "active")
    profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "repayment",
      principal_balance: "10000",
      accrued_interest_balance: "0",
      repayment_assumptions: {
        "annual_income" => "65000",
        "poverty_guideline" => "15650",
        "selected_plan_codes" => [ "standard_10_year", "rap_estimated_2026" ],
        "rap_rules" => {
          "version" => "draft",
          "forgiveness_months" => 240,
          "brackets" => []
        }
      }
    )
    profile.save!

    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        federal_student_loan: {
          enabled: "1",
          subsidy_type: "unsubsidized",
          school_status: "repayment",
          principal_balance: "10000",
          accrued_interest_balance: "0",
          repayment_assumptions: {
            annual_income: "72000"
          }
        }
      }
    }

    assert_redirected_to account_path(@account, tab: "overview")
    assumptions = @account.reload.debt_profile.federal_student_loan.repayment_assumptions
    assert_equal "72000", assumptions["annual_income"]
    assert_equal "15650", assumptions["poverty_guideline"]
    assert_equal [ "standard_10_year", "rap_estimated_2026" ], assumptions["selected_plan_codes"]
    assert_equal "draft", assumptions.dig("rap_rules", "version")
  end

  test "federal weighted average rate wins over generic annual rate when both are submitted" do
    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        annual_rate: "3.5",
        federal_student_loan: {
          enabled: "1",
          subsidy_type: "unsubsidized",
          school_status: "in_school",
          principal_balance: "12500",
          accrued_interest_balance: "315.42",
          weighted_average_rate: "6.12"
        }
      }
    }

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal BigDecimal("6.12"), @account.reload.debt_profile.debt_rate_periods.first.annual_rate
  end

  test "enabled federal weighted average rate ignores invalid generic annual rate" do
    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        annual_rate: "not-a-number",
        federal_student_loan: {
          enabled: "1",
          subsidy_type: "unsubsidized",
          school_status: "in_school",
          principal_balance: "12500",
          accrued_interest_balance: "315.42",
          weighted_average_rate: "6.12"
        }
      }
    }

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal BigDecimal("6.12"), @account.reload.debt_profile.debt_rate_periods.first.annual_rate
  end

  test "disabled federal weighted average rate does not override generic annual rate" do
    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        annual_rate: "6.25",
        federal_student_loan: {
          enabled: "0",
          weighted_average_rate: "0.0"
        }
      }
    }

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal BigDecimal("6.25"), @account.reload.debt_profile.debt_rate_periods.first.annual_rate
  end

  test "update syncs federal student loan balance to manual loan account balance" do
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
          servicer_balance_as_of: "2026-05-28"
        }
      }
    }

    @account.reload

    assert_equal BigDecimal("12815.42"), @account.balance
    reconciliation = @account.entries.valuations.find_by(date: Date.current)
    assert_equal BigDecimal("12815.42"), reconciliation.amount
    assert_equal "reconciliation", reconciliation.entryable.kind
  end

  test "update does not create balance reconciliation when federal balance is unchanged" do
    @account.update!(balance: 12815.42.to_d)
    profile = DebtProfile.create!(account: @account, status: "active")
    profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "in_school",
      principal_balance: "12500",
      accrued_interest_balance: "315.42"
    )
    profile.save!

    assert_no_difference -> { @account.entries.valuations.count } do
      patch account_debt_profile_path(@account), params: {
        debt_profile: {
          status: "active",
          federal_student_loan: {
            enabled: "1",
            subsidy_type: "unsubsidized",
            school_status: "in_school",
            principal_balance: "12500",
            accrued_interest_balance: "315.42"
          }
        }
      }
    end

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal BigDecimal("12815.42"), @account.reload.balance
  end

  test "update syncs cleared federal student loan balances to zero" do
    profile = DebtProfile.create!(account: @account, status: "active")
    profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "in_school",
      principal_balance: "12500",
      accrued_interest_balance: "315.42"
    )
    profile.save!
    @account.set_current_balance(12815.42.to_d)

    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        federal_student_loan: {
          enabled: "1",
          subsidy_type: "unsubsidized",
          school_status: "in_school",
          principal_balance: "",
          accrued_interest_balance: ""
        }
      }
    }

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal 0.to_d, @account.reload.balance
    assert_equal 0.to_d, @account.debt_profile.federal_student_loan.principal_balance
    assert_equal 0.to_d, @account.debt_profile.federal_student_loan.accrued_interest_balance
  end

  test "update with invalid federal numeric input re-renders validation errors" do
    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        federal_student_loan: {
          enabled: "1",
          subsidy_type: "unsubsidized",
          school_status: "repayment",
          principal_balance: "not-a-number",
          accrued_interest_balance: "100"
        }
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Federal student loan principal balance must be a number"
  end

  test "update with non-finite federal balance does not sync account balance" do
    original_balance = @account.balance

    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        federal_student_loan: {
          enabled: "1",
          subsidy_type: "unsubsidized",
          school_status: "repayment",
          principal_balance: "NaN",
          accrued_interest_balance: "100"
        }
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Federal student loan principal balance must be a number"
    assert_equal original_balance, @account.reload.balance
  end

  test "update with invalid annual rate re-renders rate period validation errors" do
    patch account_debt_profile_path(@account), params: {
      debt_profile: {
        status: "active",
        annual_rate: "not-a-number"
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Annual rate is not a number"
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
