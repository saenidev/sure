class Loan < ApplicationRecord
  include Accountable

  after_save :clear_federal_student_loan_profile, if: -> { saved_change_to_subtype? && !student_loan? }

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze
  RATE_TYPES = %w[fixed variable adjustable].freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  validates :rate_type, inclusion: { in: RATE_TYPES }, allow_blank: true
  validates :initial_balance, :interest_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :term_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != "fixed"
    return Money.new(0, account.currency) if account.loan.original_balance.amount.zero? || term_months.zero?

    annual_rate = interest_rate / 100.0
    monthly_rate = annual_rate / 12.0

    if monthly_rate.zero?
      payment = account.loan.original_balance.amount / term_months
    else
      payment = (account.loan.original_balance.amount * monthly_rate * (1 + monthly_rate)**term_months) / ((1 + monthly_rate)**term_months - 1)
    end

    Money.new(payment.round, account.currency)
  end

  def debt_default_rate_type
    rate_type
  end

  def debt_default_annual_rate
    interest_rate
  end

  def debt_default_monthly_payment
    monthly_payment&.amount
  end

  def original_balance
    return Money.new(initial_balance, account.currency) unless initial_balance.nil?

    account.first_valuation_amount
  end

  def student_loan?
    subtype == "student"
  end

  def clear_federal_student_loan_profile
    account&.debt_profile&.clear_federal_student_loan!
  end

  class << self
    def color
      "#D444F1"
    end

    def icon
      "hand-coins"
    end

    def classification
      "liability"
    end
  end
end
