module Debt
  module FederalStudentLoan
    RepaymentProjectionMonth = Data.define(
      :month_index,
      :starting_principal,
      :starting_accrued_interest,
      :interest_accrued,
      :payment,
      :interest_paid,
      :principal_paid,
      :ending_principal,
      :ending_accrued_interest
    )
  end
end
