module Debt
  module FederalStudentLoan
    class PaymentAllocator
      def initialize(profile:, entry:, obligation:)
        @profile = profile
        @federal_profile = profile.federal_student_loan
        @entry = entry
        @obligation = obligation
      end

      def enabled?
        federal_profile.enabled?
      end

      def allocate(fee_due_amount: 0.to_d)
        return nil unless enabled?

        remaining = entry.amount.abs
        fee = [ remaining, fee_due_amount.to_d ].min
        remaining -= fee
        interest = [ remaining, federal_profile.accrued_interest_balance ].min
        remaining -= interest
        principal = [ remaining, federal_profile.principal_balance ].min
        remaining -= principal

        {
          fee: fee,
          interest: interest,
          principal: principal,
          unapplied: remaining
        }
      end

      def after_create!(allocation)
        return unless enabled?

        federal_profile.apply_payment!(
          interest_amount: allocation.interest_amount,
          principal_amount: allocation.principal_amount
        )
        profile.save!
      end

      private
        attr_reader :profile, :federal_profile, :entry, :obligation
    end
  end
end
