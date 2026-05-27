class DebtPaymentAllocation < ApplicationRecord
  METHODS = %w[automatic manual].freeze
  STATUSES = %w[allocated estimated needs_review voided].freeze

  belongs_to :account
  belongs_to :entry
  belongs_to :debt_profile, optional: true
  belongs_to :debt_obligation, optional: true

  validates :allocation_method, presence: true, inclusion: { in: METHODS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :currency, presence: true
  validates :principal_amount, :interest_amount, :fee_amount, :unapplied_amount,
            numericality: { greater_than_or_equal_to: 0 }
  validate :account_must_be_liability
  validate :entry_belongs_to_account
  validate :entry_is_liability_payment
  validate :components_equal_payment_magnitude_unless_review

  def component_total
    principal_amount + interest_amount + fee_amount + unapplied_amount
  end

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end

    def entry_belongs_to_account
      return if entry.blank? || account.blank? || entry.account_id == account.id

      errors.add(:entry, "must belong to account")
    end

    def entry_is_liability_payment
      return if entry.blank?
      return if entry.amount.negative?

      errors.add(:entry, "must decrease liability balance")
    end

    def components_equal_payment_magnitude_unless_review
      return if status == "needs_review"
      return if entry.blank?
      return if component_total == entry.amount.abs

      errors.add(:base, "allocation components must equal payment magnitude")
    end
end
