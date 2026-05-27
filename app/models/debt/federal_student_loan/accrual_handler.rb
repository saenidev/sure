module Debt
  module FederalStudentLoan
    class AccrualHandler
      def initialize(debt_profile)
        @debt_profile = debt_profile
        @federal_profile = debt_profile.federal_student_loan
        @policy = InterestPolicy.new(debt_profile)
      end

      def enabled?
        federal_profile.enabled?
      end

      def accrues_interest?
        policy.accrues_interest?
      end

      def interest_basis_amount(account_balance:)
        policy.interest_basis_amount(account_balance: account_balance)
      end

      def day_count_denominator
        enabled? ? 365.25.to_d : 365.to_d
      end

      def mark_non_accruing_period!(period_end)
        return unless enabled?

        debt_profile.update!(last_accrued_on: period_end)
      end

      def after_post!(amount)
        return unless enabled?

        federal_profile.increment_accrued_interest!(amount)
        debt_profile.save!
      end

      private
        attr_reader :debt_profile, :federal_profile, :policy
    end
  end
end
