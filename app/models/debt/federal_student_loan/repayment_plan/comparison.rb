module Debt
  module FederalStudentLoan
    module RepaymentPlan
      class Comparison
        def initialize(debt_profile)
          @debt_profile = debt_profile
          @federal_profile = debt_profile.federal_student_loan
        end

        def call
          return [] unless debt_profile.account.student_loan?
          return [] unless federal_profile.enabled?

          federal_profile.selected_plan_codes.filter_map { |code| project(code) }
        end

        private
          attr_reader :debt_profile, :federal_profile

          def project(code)
            case code
            when "standard_10_year"
              Standard.new(
                principal: federal_profile.principal_balance,
                accrued_interest: federal_profile.accrued_interest_balance,
                annual_rate: annual_rate,
                months: 120,
                currency: debt_profile.account.currency
              ).project
            when "ibr"
              return unavailable_projection(
                code: "ibr",
                name: "IBR",
                warning: "IBR requires income assumptions before an estimate can be shown."
              ) unless ibr_assumptions_present?

              standard = Standard.new(
                principal: federal_profile.principal_balance,
                accrued_interest: federal_profile.accrued_interest_balance,
                annual_rate: annual_rate,
                months: 120,
                currency: debt_profile.account.currency
              ).project
              Ibr.new(
                principal: federal_profile.principal_balance,
                accrued_interest: federal_profile.accrued_interest_balance,
                annual_rate: annual_rate,
                annual_income: assumptions.fetch("annual_income", 0),
                poverty_guideline: assumptions.fetch("poverty_guideline", 15_650),
                new_borrower: assumptions.fetch("new_ibr_borrower", true),
                standard_monthly_payment: standard.first_payment_amount,
                currency: debt_profile.account.currency
              ).project
            when "rap_estimated_2026"
              Rap.new(
                principal: federal_profile.principal_balance,
                accrued_interest: federal_profile.accrued_interest_balance,
                annual_rate: annual_rate,
                annual_income: assumptions.fetch("annual_income", 0),
                dependent_count: assumptions.fetch("dependent_count", 0),
                rules: assumptions["rap_rules"],
                currency: debt_profile.account.currency
              ).project
            when "tiered_standard_estimated_2026"
              unavailable_projection(
                code: "tiered_standard_estimated_2026",
                name: "Tiered Standard estimate",
                warning: "Tiered Standard requires versioned rules before an estimate can be shown."
              )
            end
          end

          def assumptions
            federal_profile.repayment_assumptions
          end

          def ibr_assumptions_present?
            assumption_present?("annual_income") && assumption_present?("poverty_guideline")
          end

          def assumption_present?(key)
            assumptions.key?(key) && assumptions[key].present?
          end

          def annual_rate
            Debt::AccountTerms.new(debt_profile.account).resolve.annual_rate ||
              federal_profile.weighted_average_rate ||
              0.to_d
          end

          def unavailable_projection(code:, name:, warning:)
            Debt::FederalStudentLoan::RepaymentProjection.new(
              plan_code: code,
              plan_name: name,
              available: false,
              first_payment_amount: 0.to_d,
              month_count: 0,
              total_paid: 0.to_d,
              total_interest_paid: 0.to_d,
              forgiven_amount: 0.to_d,
              currency: debt_profile.account.currency,
              warnings: [ warning ],
              schedule: []
            )
          end
      end
    end
  end
end
