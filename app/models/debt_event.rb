class DebtEvent < ApplicationRecord
  EVENT_TYPES = %w[interest_accrual interest_capitalization fee principal_adjustment rate_change manual_adjustment user_observed].freeze
  STATUSES = %w[pending posted matched voided superseded].freeze
  BALANCE_CHANGING_TYPES = %w[interest_accrual fee principal_adjustment manual_adjustment].freeze

  belongs_to :account
  belongs_to :debt_profile, optional: true
  belongs_to :entry, optional: true

  has_many :debt_reconciliation_matches, dependent: :destroy

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :event_date, :currency, presence: true
  validates :amount, numericality: true
  validate :account_must_be_liability
  validate :entry_belongs_to_account
  validate :posted_or_matched_balance_changing_events_require_entry

  def balance_changing?
    BALANCE_CHANGING_TYPES.include?(event_type)
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

    def posted_or_matched_balance_changing_events_require_entry
      return unless status.in?(%w[posted matched]) && balance_changing?
      return if entry.present?

      errors.add(:entry, "must be present for posted or matched balance-changing events")
    end
end
