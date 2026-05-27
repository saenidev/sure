module Debt
  module FederalStudentLoan
    module RepaymentPlan
      class Ibr
        def initialize(principal:, accrued_interest:, annual_rate:, annual_income:, poverty_guideline:, new_borrower:, standard_monthly_payment:, currency: "USD")
          @principal = principal.to_d
          @accrued_interest = accrued_interest.to_d
          @annual_rate = annual_rate.to_d
          @annual_income = annual_income.to_d
          @poverty_guideline = poverty_guideline.to_d
          @new_borrower = ActiveModel::Type::Boolean.new.cast(new_borrower)
          @standard_monthly_payment = standard_monthly_payment.to_d
          @currency = currency
        end

        def project
          payment = [ income_based_payment, standard_monthly_payment ].min.round(2)
          months = new_borrower ? 240 : 300
          amortizer = Amortizer.new(principal: principal, accrued_interest: accrued_interest, annual_rate: annual_rate)
          schedule = amortizer.simulate(months: months, payment_for_month: ->(_month) { payment })
          ending = schedule.last
          forgiven = ending.ending_principal + ending.ending_accrued_interest

          RepaymentProjection.new(
            plan_code: "ibr",
            plan_name: "IBR",
            available: true,
            first_payment_amount: payment,
            month_count: months,
            total_paid: schedule.sum(&:payment).round(2),
            total_interest_paid: schedule.sum(&:interest_paid).round(2),
            forgiven_amount: forgiven.round(2),
            currency: currency,
            warnings: [ "IBR estimate uses supplied poverty guideline and does not certify eligibility." ],
            schedule: schedule
          )
        end

        private
          attr_reader :principal, :accrued_interest, :annual_rate, :annual_income, :poverty_guideline, :new_borrower, :standard_monthly_payment, :currency

          def income_based_payment
            discretionary_income = [ annual_income - (poverty_guideline * 1.5), 0.to_d ].max
            percent = new_borrower ? 0.10.to_d : 0.15.to_d

            discretionary_income * percent / 12
          end
      end
    end
  end
end
