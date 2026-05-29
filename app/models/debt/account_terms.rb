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

    # `rate_periods` lets a caller inject a preloaded, authoritative snapshot of the
    # profile's debt_rate_periods so resolve never issues a `for_date` query. This
    # is used by the forecast adapter, which materializes a fresh array ONCE per
    # account (from its eager-load) and resolves terms for many periods in a hot
    # loop. Pass nil (the default) to keep the original behavior of querying
    # `for_date` per call, which every other caller relies on for authoritative,
    # never-stale rate resolution.
    def initialize(account, as_of: Date.current, rate_periods: nil)
      @account = account
      @as_of = as_of
      @rate_periods = rate_periods
    end

    def resolve
      rate_period = rate_period_for(as_of)
      federal_weighted_rate = federal_student_loan_weighted_rate
      annual_rate = decimal_or_nil(rate_period&.annual_rate || federal_weighted_rate || account_default(:debt_default_annual_rate))
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
        source: source_for(rate_period, federal_weighted_rate)
      )
    end

    private
      attr_reader :account, :as_of, :rate_periods

      def profile
        @profile ||= account.debt_profile
      end

      # Resolve the active rate period for `as_of`. When a caller injects a
      # preloaded `rate_periods` snapshot, select from it in Ruby (zero DB
      # queries), mirroring the `for_date` scope exactly: same predicate
      # (starts_on <= as_of AND (ends_on nil OR ends_on >= as_of)) and the same
      # ORDER BY priority DESC, starts_on DESC -> first winner. Otherwise issue the
      # authoritative `for_date` query so non-injecting callers never read a stale
      # association cache.
      def rate_period_for(as_of)
        return profile&.debt_rate_periods&.for_date(as_of)&.first if rate_periods.nil?

        rate_periods
          .select { |rate_period| rate_period.starts_on <= as_of && (rate_period.ends_on.nil? || rate_period.ends_on >= as_of) }
          .min_by { |rate_period| [ -rate_period.priority, -rate_period.starts_on.jd ] }
      end

      def account_default(method_name)
        return nil unless account.accountable.respond_to?(method_name)

        account.accountable.public_send(method_name)
      end

      def federal_student_loan_weighted_rate
        return nil unless account.student_loan?
        return nil unless profile&.federal_student_loan&.enabled?
        return nil if profile.federal_student_loan.input_value(:weighted_average_rate).blank?

        profile.federal_student_loan.weighted_average_rate.presence
      end

      def source_for(rate_period, federal_weighted_rate)
        return "rate_period" if rate_period.present?
        return "federal_student_loan" if federal_weighted_rate.present?

        "account"
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
