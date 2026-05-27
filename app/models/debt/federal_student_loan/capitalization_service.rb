module Debt
  module FederalStudentLoan
    class CapitalizationService
      SOURCE = "sure"

      def initialize(account:, as_of: Date.current, reason:)
        @account = account
        @profile = account.debt_profile
        @as_of = as_of
        @reason = reason
      end

      def call
        return nil unless account.manual_debt_account?
        return nil unless profile&.active?
        return nil unless federal_profile.enabled?
        return existing_event if existing_event.present?
        return nil unless federal_profile.accrued_interest_balance.positive?

        DebtEvent.transaction do
          profile.lock!
          return existing_event if existing_event.present?
          return nil unless federal_profile.accrued_interest_balance.positive?

          amount = federal_profile.accrued_interest_balance

          event = account.debt_events.create!(
            debt_profile: profile,
            event_type: "interest_capitalization",
            status: "posted",
            event_date: as_of,
            amount: amount,
            currency: account.currency,
            source: SOURCE,
            external_id: external_id,
            idempotency_key: external_id,
            extra: { "reason" => reason }
          )

          federal_profile.capitalize_interest!(amount)
          profile.save!
          event
        end
      end

      private
        attr_reader :account, :profile, :as_of, :reason

        def federal_profile
          @federal_profile ||= profile.federal_student_loan
        end

        def external_id
          "federal-student-loan-capitalization-#{as_of}-#{reason}"
        end

        def existing_event
          account.debt_events.find_by(source: SOURCE, external_id: external_id)
        end
    end
  end
end
