class DebtReconciliationMatch < ApplicationRecord
  MATCH_TYPES = %w[exact date_amount manual].freeze
  CONFIDENCES = %w[high medium low].freeze
  STATUSES = %w[accepted dismissed needs_review].freeze

  belongs_to :account
  belongs_to :debt_event
  belongs_to :entry

  after_save :mark_event_matched, if: :accepted?

  validates :match_type, presence: true, inclusion: { in: MATCH_TYPES }
  validates :confidence, presence: true, inclusion: { in: CONFIDENCES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :records_belong_to_account

  def accepted?
    status == "accepted"
  end

  private
    def records_belong_to_account
      errors.add(:debt_event, "must belong to account") if debt_event && debt_event.account_id != account_id
      errors.add(:entry, "must belong to account") if entry && entry.account_id != account_id
    end

    def mark_event_matched
      debt_event.update!(entry: entry, status: "matched")
    end
end
