module Debt
  class AccountTerms
    Result = Data.define(
      :account,
      :accrual_ready,
      :missing_fields,
      :rate_type,
      :annual_rate,
      :monthly_payment,
      :opening_balance,
      :currency,
      :source
    ) do
      def accrual_ready?
        accrual_ready
      end
    end

    def initialize(account, as_of: Date.current)
      @account = account
      @as_of = as_of
    end

    def resolve
      rate_period = profile&.debt_rate_periods&.for_date(as_of)&.first
      annual_rate = decimal_or_nil(rate_period&.annual_rate || account_default(:debt_default_annual_rate))
      rate_type = rate_period&.rate_type || profile&.rate_type || account_default(:debt_default_rate_type)
      monthly_payment = decimal_or_nil(profile&.minimum_payment_amount || account_default(:debt_default_monthly_payment))
      opening_balance = decimal_or_nil(account.balance)
      missing_fields = missing_fields_for(annual_rate, opening_balance)

      Result.new(
        account: account,
        accrual_ready: account.liability? && missing_fields.empty?,
        missing_fields: missing_fields,
        rate_type: rate_type,
        annual_rate: annual_rate,
        monthly_payment: monthly_payment,
        opening_balance: opening_balance,
        currency: account.currency,
        source: rate_period.present? ? "rate_period" : "account"
      )
    end

    private
      attr_reader :account, :as_of

      def profile
        @profile ||= account.debt_profile
      end

      def account_default(method_name)
        return nil unless account.accountable.respond_to?(method_name)

        account.accountable.public_send(method_name)
      end

      def decimal_or_nil(value)
        return nil if value.blank?

        value.to_d
      end

      def missing_fields_for(annual_rate, opening_balance)
        missing = []
        missing << :annual_rate if annual_rate.blank?
        missing << :opening_balance if opening_balance.blank?
        missing
      end
  end
end
