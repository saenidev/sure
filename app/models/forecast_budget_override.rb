class ForecastBudgetOverride < ApplicationRecord
  include Monetizable

  OVERRIDE_TYPES = %w[expected_income category_spending uncategorized_spending].freeze
  STATUSES = %w[active disabled archived].freeze

  belongs_to :family
  belongs_to :forecast_scenario, optional: true
  belongs_to :category, optional: true

  monetize :amount

  before_validation :canonicalize_period_start_on

  validates :period_start_on, :override_type, :amount, :currency, :status, presence: true
  validates :override_type, inclusion: { in: OVERRIDE_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validate :category_required_for_category_spending
  validate :category_absent_unless_category_spending
  validate :category_must_be_parent_for_category_spending
  validate :associations_belong_to_family
  validate :scenario_covers_entire_budget_period
  validate :active_override_is_unique_for_scope

  private
    def canonicalize_period_start_on
      return if family.blank? || period_start_on.blank?

      self.period_start_on = family.custom_month_start_for(period_start_on)
    end

    def category_required_for_category_spending
      return unless override_type == "category_spending"
      return if category.present?

      errors.add(:category, "must be present for category spending overrides")
    end

    def category_absent_unless_category_spending
      return if override_type == "category_spending"
      return if category.blank?

      errors.add(:category, "must be blank unless this is a category spending override")
    end

    def category_must_be_parent_for_category_spending
      return unless override_type == "category_spending"
      return if category.blank?
      return if category.parent_id.blank?

      errors.add(:category, "must be a parent category for forecast budget overrides")
    end

    def associations_belong_to_family
      if forecast_scenario.present? && forecast_scenario.family_id != family_id
        errors.add(:forecast_scenario, "must belong to the forecast family")
      end

      if category.present? && category.family_id != family_id
        errors.add(:category, "must belong to the forecast family")
      end
    end

    def scenario_covers_entire_budget_period
      return if forecast_scenario.blank? || family.blank? || period_start_on.blank?

      period_end_on = family.custom_month_end_for(period_start_on)
      starts_after_period_start = forecast_scenario.starts_on.present? && forecast_scenario.starts_on > period_start_on
      ends_before_period_end = forecast_scenario.ends_on.present? && forecast_scenario.ends_on < period_end_on
      return unless starts_after_period_start || ends_before_period_end

      errors.add(:period_start_on, "must be fully covered by the scenario date window")
    end

    def active_override_is_unique_for_scope
      return unless status == "active"
      return if family_id.blank? || period_start_on.blank? || override_type.blank?

      duplicate = self.class
        .where(family_id: family_id, status: "active", period_start_on: period_start_on, override_type: override_type)
        .where(forecast_scenario_id: forecast_scenario_id)
        .where(category_id: category_id)
      duplicate = duplicate.where.not(id: id) if persisted?
      return unless duplicate.exists?

      errors.add(:base, "active forecast budget override already exists for this period, scenario, type, and category")
    end
end
