module Debt
  class ObligationService
    SOURCE = "sure"

    def initialize(account:, as_of: Date.current)
      @account = account
      @as_of = as_of
    end

    def generate_next
      return nil unless account.manual_debt_account?
      return nil unless profile&.active?
      return nil if profile.payment_due_day.blank?

      due_on = next_due_date
      obligation = account.debt_obligations.find_or_initialize_by(
        source: SOURCE,
        external_id: external_id_for(due_on)
      )
      if obligation.persisted?
        profile.update!(next_due_on: due_on)
        return obligation
      end

      period_start_on = period_start_for(due_on)
      period_end_on = due_on
      interest_due_amount = balance_changing_event_sum("interest_accrual", period_start_on, period_end_on)
      fee_due_amount = balance_changing_event_sum("fee", period_start_on, period_end_on)
      minimum_due = minimum_payment_amount
      principal_due_amount = [ minimum_due - interest_due_amount - fee_due_amount, 0.to_d ].max

      obligation.assign_attributes(
        debt_profile: profile,
        period_start_on: period_start_on,
        period_end_on: period_end_on,
        due_on: due_on,
        status: "open",
        statement_balance_amount: account.balance,
        minimum_payment_amount: minimum_due,
        principal_due_amount: principal_due_amount,
        interest_due_amount: interest_due_amount,
        fee_due_amount: fee_due_amount,
        currency: account.currency
      )
      obligation.save!
      profile.update!(next_due_on: due_on)
      obligation
    end

    def upsert_manual(attributes)
      return nil unless account.manual_debt_account?

      due_on = attributes.fetch(:due_on)
      external_id = attributes[:external_id].presence || "manual:#{due_on}"
      obligation = account.debt_obligations.find_or_initialize_by(source: "manual", external_id: external_id)
      obligation.assign_attributes(attributes.merge(debt_profile: profile, currency: attributes[:currency].presence || account.currency))
      obligation.save!
      obligation
    end

    private
      attr_reader :account, :as_of

      def profile
        @profile ||= account.debt_profile
      end

      def next_due_date
        due_on = date_for_day(as_of.year, as_of.month, profile.payment_due_day)
        due_on < as_of ? date_for_day(as_of.next_month.year, as_of.next_month.month, profile.payment_due_day) : due_on
      end

      def date_for_day(year, month, day)
        last_day = Date.new(year, month, -1).day
        Date.new(year, month, [ day, last_day ].min)
      end

      def minimum_payment_amount
        profile_values = [ profile.minimum_payment_amount, percent_minimum_payment ].compact.map(&:to_d)
        return profile_values.max if profile_values.any?

        AccountTerms.new(account, as_of: as_of).resolve.monthly_payment || 0.to_d
      end

      def period_start_for(due_on)
        account.debt_obligations
          .where(source: SOURCE)
          .where("due_on < ?", due_on)
          .maximum(:due_on)&.next_day || due_on.prev_month.next_day
      end

      def balance_changing_event_sum(event_type, period_start_on, period_end_on)
        account.debt_events
          .where(event_type: event_type, status: %w[posted matched])
          .where(event_date: period_start_on..period_end_on)
          .sum(:amount)
          .to_d
      end

      def percent_minimum_payment
        return nil if profile.minimum_payment_percent.blank?

        (account.balance.to_d * profile.minimum_payment_percent.to_d / 100).round(4)
      end

      def external_id_for(due_on)
        "debt-obligation-#{account.id}-#{due_on}"
      end
  end
end
