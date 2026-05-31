class ForecastBudgetPlanAmount < ApplicationRecord
  include Monetizable

  AMOUNT_TYPES = ForecastBudgetOverride::OVERRIDE_TYPES

  belongs_to :family
  belongs_to :forecast_budget_plan
  belongs_to :category, optional: true

  monetize :amount

  before_validation :canonicalize_period_start_on

  validates :period_start_on, :amount_type, :amount, :currency, presence: true
  validates :amount_type, inclusion: { in: AMOUNT_TYPES }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validate :category_required_for_category_spending
  validate :category_absent_unless_category_spending
  validate :category_must_be_parent_for_category_spending
  validate :associations_belong_to_family
  validate :period_inside_plan_horizon
  validate :amount_is_unique_for_plan_period_key

  def amount_key
    [ amount_type, category_id ]
  end

  private
    def canonicalize_period_start_on
      return if family.blank? || period_start_on.blank?

      self.period_start_on = family.custom_month_start_for(period_start_on)
    end

    def category_required_for_category_spending
      return unless amount_type == "category_spending"
      return if category.present?

      errors.add(:category, "must be present for category spending forecast budget plan amounts")
    end

    def category_absent_unless_category_spending
      return if amount_type == "category_spending"
      return if category.blank?

      errors.add(:category, "must be blank unless this is a category spending amount")
    end

    def category_must_be_parent_for_category_spending
      return unless amount_type == "category_spending"
      return if category.blank?
      return if category.parent_id.blank?

      errors.add(:category, "must be a parent category for forecast budget plans")
    end

    def associations_belong_to_family
      if forecast_budget_plan.present? && forecast_budget_plan.family_id != family_id
        errors.add(:forecast_budget_plan, "must belong to the forecast family")
      end

      if category.present? && category.family_id != family_id
        errors.add(:category, "must belong to the forecast family")
      end
    end

    def period_inside_plan_horizon
      return if forecast_budget_plan.blank? || period_start_on.blank?
      return if forecast_budget_plan.horizon_start_on.blank? || forecast_budget_plan.horizon_end_on.blank?

      period_end_on = family&.custom_month_end_for(period_start_on) || period_start_on.end_of_month
      starts_before_horizon = period_start_on < forecast_budget_plan.horizon_start_on
      ends_after_horizon = period_end_on > forecast_budget_plan.horizon_end_on
      return unless starts_before_horizon || ends_after_horizon

      errors.add(:period_start_on, "must be inside the forecast budget plan timeline")
    end

    def amount_is_unique_for_plan_period_key
      return if forecast_budget_plan_id.blank? || period_start_on.blank? || amount_type.blank?

      duplicate = self.class
        .where(
          forecast_budget_plan_id: forecast_budget_plan_id,
          period_start_on: period_start_on,
          amount_type: amount_type,
          category_id: category_id
        )
      duplicate = duplicate.where.not(id: id) if persisted?
      return unless duplicate.exists?

      errors.add(:base, "forecast budget plan amount already exists for this month and row")
    end
end
