module Debt
  module FederalStudentLoan
    module RepaymentPlan
      class Standard
        def initialize(principal:, accrued_interest:, annual_rate:, months:, currency: "USD")
          @principal = principal.to_d
          @accrued_interest = accrued_interest.to_d
          @annual_rate = annual_rate.to_d
          @months = months.to_i
          @currency = currency
        end

        def project
          amortizer = Amortizer.new(principal: principal, accrued_interest: accrued_interest, annual_rate: annual_rate)
          payment = amortizer.fixed_payment_to_zero(months: months)
          schedule = amortizer.simulate(months: months, payment_for_month: ->(_month) { payment })
          total_paid = schedule.sum(&:payment)
          total_interest_paid = schedule.sum(&:interest_paid)

          RepaymentProjection.new(
            plan_code: "standard_10_year",
            plan_name: "Standard",
            available: true,
            first_payment_amount: payment,
            month_count: months,
            total_paid: total_paid.round(2),
            total_interest_paid: total_interest_paid.round(2),
            forgiven_amount: 0.to_d,
            currency: currency,
            warnings: [],
            schedule: schedule
          )
        end

        private
          attr_reader :principal, :accrued_interest, :annual_rate, :months, :currency
      end
    end
  end
end
