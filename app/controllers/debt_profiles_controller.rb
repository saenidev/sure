class DebtProfilesController < ApplicationController
  before_action :set_account
  before_action :require_manual_debt_account
  before_action :set_debt_profile

  def edit
  end

  def update
    if update_debt_profile
      redirect_to account_path(@account, tab: "overview"), notice: t(".success")
    else
      @error_message = @debt_profile.errors.full_messages.join(", ")
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
      require_account_permission!(@account)
    end

    def require_manual_debt_account
      return if performed?
      return if @account.debt_mechanics_supported?

      redirect_to account_path(@account), alert: t("debt_profiles.unsupported")
    end

    def set_debt_profile
      return if performed?

      @debt_profile = @account.debt_profile || @account.build_debt_profile(default_profile_attributes)
    end

    def default_profile_attributes
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

    def update_debt_profile
      annual_rate = debt_profile_params[:annual_rate]

      DebtProfile.transaction do
        @debt_profile.update!(debt_profile_params.except(:annual_rate))
        upsert_manual_rate_period!(annual_rate) if annual_rate.present?
      end

      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    def upsert_manual_rate_period!(annual_rate)
      rate_period = @debt_profile.debt_rate_periods.for_date(Date.current).find_by(source: "manual") ||
        @debt_profile.debt_rate_periods.build(source: "manual", starts_on: @debt_profile.effective_start_on || Date.current, priority: 100)

      rate_period.update!(
        rate_type: @debt_profile.rate_type.presence || Debt::AccountTerms.new(@account).resolve.rate_type || "variable",
        annual_rate: annual_rate
      )
    end

    def debt_profile_params
      params.require(:debt_profile).permit(
        :status,
        :auto_accrual_enabled,
        :auto_payment_allocation_enabled,
        :rate_type,
        :annual_rate,
        :accrual_cadence,
        :compounding_cadence,
        :minimum_payment_amount,
        :minimum_payment_percent,
        :payment_due_day,
        :statement_closing_day,
        :grace_period_days,
        :effective_start_on,
        :effective_end_on
      )
    end
end
