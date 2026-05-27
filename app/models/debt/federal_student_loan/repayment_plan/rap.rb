module Debt
  module FederalStudentLoan
    module RepaymentPlan
      class Rap
        def initialize(principal:, accrued_interest:, annual_rate:, annual_income:, dependent_count:, rules:, currency: "USD")
          @principal = principal.to_d
          @accrued_interest = accrued_interest.to_d
          @annual_rate = annual_rate.to_d
          @annual_income = annual_income.to_d
          @dependent_count = dependent_count.to_i
          @rules = rules
          @currency = currency
        end

        def project
          return unavailable_projection if rules.blank?

          payment = [ gross_monthly_payment - dependent_discount, minimum_monthly_payment ].max.round(2)
          months = rules.fetch("forgiveness_months").to_i
          amortizer = Amortizer.new(principal: principal, accrued_interest: accrued_interest, annual_rate: annual_rate)
          schedule = amortizer.simulate(months: months, payment_for_month: ->(_month) { payment })
          ending = schedule.last

          RepaymentProjection.new(
            plan_code: "rap_estimated_2026",
            plan_name: "RAP estimate",
            available: true,
            first_payment_amount: payment,
            month_count: months,
            total_paid: schedule.sum(&:payment).round(2),
            total_interest_paid: schedule.sum(&:interest_paid).round(2),
            forgiven_amount: (ending.ending_principal + ending.ending_accrued_interest).round(2),
            currency: currency,
            warnings: [ "RAP estimate uses version #{rules.fetch("version")} rules; verify against current StudentAid guidance before relying on it." ],
            schedule: schedule
          )
        end

        private
          attr_reader :principal, :accrued_interest, :annual_rate, :annual_income, :dependent_count, :rules, :currency

          def unavailable_projection
            RepaymentProjection.new(
              plan_code: "rap_estimated_2026",
              plan_name: "RAP estimate",
              available: false,
              first_payment_amount: 0.to_d,
              month_count: 0,
              total_paid: 0.to_d,
              total_interest_paid: 0.to_d,
              forgiven_amount: 0.to_d,
              currency: currency,
              warnings: [ "RAP requires versioned RAP rules before an estimate can be shown." ],
              schedule: []
            )
          end

          def gross_monthly_payment
            annual_income * bracket_percent / 100 / 12
          end

          def bracket_percent
            bracket = rules.fetch("brackets").find do |row|
              min = row.fetch("min_income").to_d
              max = row["max_income"]&.to_d
              annual_income >= min && (max.nil? || annual_income < max)
            end

            bracket.fetch("annual_percent").to_d
          end

          def dependent_discount
            rules.fetch("dependent_monthly_discount").to_d * dependent_count
          end

          def minimum_monthly_payment
            rules.fetch("minimum_monthly_payment").to_d
          end
      end
    end
  end
end
