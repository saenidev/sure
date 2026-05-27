module Debt
  module FederalStudentLoan
    class InterestPolicy
      NON_ACCRUING_SUBSIDIZED_STATUSES = %w[in_school grace deferment].freeze

      def initialize(debt_profile)
        @debt_profile = debt_profile
        @federal_profile = debt_profile.federal_student_loan
      end

      def generic_debt_mode?
        !federal_profile.enabled?
      end

      def accrues_interest?
        return true if generic_debt_mode?

        if federal_profile.subsidy_type == "subsidized"
          return false if NON_ACCRUING_SUBSIDIZED_STATUSES.include?(federal_profile.school_status)
        end

        if federal_profile.subsidy_type == "mixed" &&
            NON_ACCRUING_SUBSIDIZED_STATUSES.include?(federal_profile.school_status)
          return mixed_interest_basis.positive?
        end

        true
      end

      def interest_basis_amount(account_balance:)
        return account_balance.to_d if generic_debt_mode?

        if federal_profile.subsidy_type == "mixed" &&
            NON_ACCRUING_SUBSIDIZED_STATUSES.include?(federal_profile.school_status)
          return mixed_interest_basis
        end

        federal_profile.principal_balance
      end

      private
        attr_reader :debt_profile, :federal_profile

        def mixed_interest_basis
          federal_profile.interest_bearing_principal_balance
        end
    end
  end
end
