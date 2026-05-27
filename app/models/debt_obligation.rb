class DebtObligation < ApplicationRecord
  STATUSES = %w[open partially_paid paid overdue waived superseded].freeze

  belongs_to :account
  belongs_to :debt_profile, optional: true
  has_many :debt_payment_allocations, dependent: :nullify

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :due_on, :currency, presence: true
  validates :statement_balance_amount, :minimum_payment_amount, :principal_due_amount,
            :interest_due_amount, :fee_due_amount, :paid_amount,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :account_must_be_liability
  validate :period_dates_ordered

  def amount_due
    minimum_payment_amount || statement_balance_amount || 0.to_d
  end

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end

    def period_dates_ordered
      return if period_start_on.blank? || period_end_on.blank?
      return if period_end_on >= period_start_on

      errors.add(:period_end_on, "must be on or after period_start_on")
    end
end
