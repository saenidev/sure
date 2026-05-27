class DebtRatePeriod < ApplicationRecord
  RATE_TYPES = DebtProfile::RATE_TYPES

  belongs_to :debt_profile

  validates :rate_type, presence: true, inclusion: { in: RATE_TYPES }
  validates :annual_rate, numericality: { greater_than_or_equal_to: 0 }
  validates :starts_on, presence: true
  validates :priority, numericality: { only_integer: true }
  validate :ends_on_not_before_starts_on
  validate :does_not_overlap_same_priority

  scope :for_date, ->(date) {
    where("starts_on <= ?", date)
      .where("ends_on IS NULL OR ends_on >= ?", date)
      .order(priority: :desc, starts_on: :desc)
  }

  private
    def ends_on_not_before_starts_on
      return if starts_on.blank? || ends_on.blank?
      return if ends_on >= starts_on

      errors.add(:ends_on, "must be on or after starts_on")
    end

    def does_not_overlap_same_priority
      return if debt_profile_id.blank? || starts_on.blank?

      relation = self.class
        .where(debt_profile_id: debt_profile_id, priority: priority)
        .where.not(id: id)
        .where("starts_on <= ?", ends_on || Date.new(9999, 12, 31))
        .where("ends_on IS NULL OR ends_on >= ?", starts_on)

      errors.add(:starts_on, "overlaps an existing rate period") if relation.exists?
    end
end
