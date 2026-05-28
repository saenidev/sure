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
          return unavailable_projection("RAP requires versioned RAP rules before an estimate can be shown.") if rules.blank?
          return unavailable_projection("RAP estimate rules are incomplete; verify the versioned rule set before relying on it.") unless rules_complete?
          return unavailable_projection("RAP estimate rules do not cover the supplied annual income.") if matching_bracket.blank?

          payment = [ gross_monthly_payment - dependent_discount, minimum_monthly_payment ].max.round(2)
          months = rules["forgiveness_months"].to_i
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
            warnings: [ "RAP estimate uses version #{rules["version"]} rules; verify against current StudentAid guidance before relying on it." ],
            schedule: schedule
          )
        end

        private
          attr_reader :principal, :accrued_interest, :annual_rate, :annual_income, :dependent_count, :rules, :currency

          def unavailable_projection(warning)
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
              warnings: [ warning ],
              schedule: []
            )
          end

          def rules_complete?
            rules["version"].present? &&
              positive_integer?(rules["forgiveness_months"]) &&
              nonnegative_decimal?(rules["dependent_monthly_discount"]) &&
              nonnegative_decimal?(rules["minimum_monthly_payment"]) &&
              rules["brackets"].is_a?(Array) &&
              rules["brackets"].all? { |row| bracket_complete?(row) }
          end

          def gross_monthly_payment
            annual_income * bracket_percent / 100 / 12
          end

          def bracket_percent
            decimal_value(matching_bracket.fetch("annual_percent"))
          end

          def matching_bracket
            @matching_bracket ||= rules["brackets"].find do |row|
              min = decimal_value(row.fetch("min_income"))
              max = row["max_income"].present? ? decimal_value(row["max_income"]) : nil
              annual_income >= min && (max.nil? || annual_income < max)
            end
          end

          def dependent_discount
            decimal_value(rules["dependent_monthly_discount"]) * dependent_count
          end

          def minimum_monthly_payment
            decimal_value(rules["minimum_monthly_payment"])
          end

          def bracket_complete?(row)
            return false unless row.respond_to?(:key?)
            return false unless row.key?("min_income") && row.key?("annual_percent")
            return false unless nonnegative_decimal?(row["min_income"])
            return false unless nonnegative_decimal?(row["annual_percent"])
            return true if row["max_income"].blank?

            max = decimal_value(row["max_income"])
            min = decimal_value(row["min_income"])

            max.present? && max > min
          end

          def positive_integer?(value)
            parsed = Integer(value.to_s, exception: false)

            parsed.present? && parsed.positive?
          end

          def nonnegative_decimal?(value)
            parsed = decimal_value(value)

            parsed.present? && !parsed.negative?
          end

          def decimal_value(value)
            return nil if value.blank?

            parsed = BigDecimal(value.to_s)
            parsed if parsed.finite?
          rescue ArgumentError
            nil
          end
      end
    end
  end
end
