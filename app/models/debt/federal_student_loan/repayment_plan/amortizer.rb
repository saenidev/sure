module Debt
  module FederalStudentLoan
    module RepaymentPlan
      class Amortizer
        def initialize(principal:, accrued_interest:, annual_rate:)
          @principal = principal.to_d
          @accrued_interest = accrued_interest.to_d
          @monthly_rate = annual_rate.to_d / 100 / 12
        end

        def fixed_payment_to_zero(months:)
          low = 0.to_d
          high = principal + accrued_interest + (principal * monthly_rate * months) + 1

          60.times do
            midpoint = (low + high) / 2
            ending = simulate(months: months, payment_for_month: ->(_month) { midpoint }).last

            if ending.ending_principal.positive? || ending.ending_accrued_interest.positive?
              low = midpoint
            else
              high = midpoint
            end
          end

          high.round(2)
        end

        def simulate(months:, payment_for_month:)
          current_principal = principal
          current_accrued_interest = accrued_interest

          (1..months).map do |month|
            starting_principal = current_principal
            starting_accrued_interest = current_accrued_interest
            interest_accrued = (current_principal * monthly_rate).round(4)
            current_accrued_interest += interest_accrued
            scheduled_payment = payment_for_month.call(month).to_d
            payment = [ scheduled_payment, current_principal + current_accrued_interest ].min
            interest_paid = [ payment, current_accrued_interest ].min
            current_accrued_interest -= interest_paid
            principal_paid = [ [ payment - interest_paid, 0.to_d ].max, current_principal ].min
            current_principal -= principal_paid

            Debt::FederalStudentLoan::RepaymentProjectionMonth.new(
              month_index: month,
              starting_principal: starting_principal.round(4),
              starting_accrued_interest: starting_accrued_interest.round(4),
              interest_accrued: interest_accrued.round(4),
              payment: payment.round(2),
              interest_paid: interest_paid.round(4),
              principal_paid: principal_paid.round(4),
              ending_principal: current_principal.round(4),
              ending_accrued_interest: current_accrued_interest.round(4)
            )
          end
        end

        private
          attr_reader :principal, :accrued_interest, :monthly_rate
      end
    end
  end
end
