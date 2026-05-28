class ForecastScenario < ApplicationRecord
  STATUSES = %w[active archived disabled].freeze
  APPROVAL_STATUSES = %w[manual pending approved rejected].freeze

  belongs_to :family
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :parent_scenario, class_name: "ForecastScenario", optional: true

  has_many :forecast_events, dependent: :destroy
  has_many :forecast_budget_overrides, dependent: :destroy
  has_many :forecast_goals, dependent: :destroy
  has_many :forecast_account_liquidity_settings, dependent: :destroy

  scope :active, -> { where(status: "active") }

  validates :name, :status, :approval_status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :approval_status, inclusion: { in: APPROVAL_STATUSES }
  validate :date_range_valid
  validate :parent_belongs_to_family
  validate :creator_belongs_to_family

  private
    def date_range_valid
      return if ends_on.blank? || starts_on.blank? || ends_on >= starts_on

      errors.add(:ends_on, "must be on or after starts_on")
    end

    def parent_belongs_to_family
      return if parent_scenario.blank? || parent_scenario.family_id == family_id

      errors.add(:parent_scenario, "must belong to the forecast family")
    end

    def creator_belongs_to_family
      return if created_by_user.blank? || created_by_user.family_id == family_id

      errors.add(:created_by_user, "must belong to the forecast family")
    end
end
