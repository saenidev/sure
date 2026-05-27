module Debt
  module FederalStudentLoan
    RepaymentProjection = Data.define(
      :plan_code,
      :plan_name,
      :available,
      :first_payment_amount,
      :month_count,
      :total_paid,
      :total_interest_paid,
      :forgiven_amount,
      :currency,
      :warnings,
      :schedule
    ) do
      def available?
        available
      end
    end

  end
end
