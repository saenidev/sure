class DebtPostingRun < ApplicationRecord
  RUN_TYPES = %w[interest_accrual payment_allocation obligation_generation reconciliation].freeze
  STATUSES = %w[started succeeded failed skipped].freeze

  belongs_to :account
  belongs_to :debt_profile, optional: true

  validates :run_type, presence: true, inclusion: { in: RUN_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :account_must_be_liability

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end
end
