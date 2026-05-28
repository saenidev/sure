class LoansController < ApplicationController
  include AccountableResource

  before_action :set_debt_profile_for_manage_modal, only: %i[edit update]

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance
  )

  private
    def set_debt_profile_for_manage_modal
      return unless @account.debt_mechanics_supported?

      @debt_profile = @account.debt_profile || @account.build_debt_profile(default_debt_profile_attributes)
    end

    def default_debt_profile_attributes
      terms = Debt::AccountTerms.new(@account).resolve

      {
        status: "active",
        rate_type: terms.rate_type,
        annual_rate: terms.annual_rate,
        accrual_cadence: "daily",
        compounding_cadence: "monthly",
        minimum_payment_amount: terms.monthly_payment
      }
    end
end
