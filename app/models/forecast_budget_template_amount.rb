class ForecastBudgetTemplateAmount < ApplicationRecord
  include Monetizable

  AMOUNT_TYPES = ForecastBudgetOverride::OVERRIDE_TYPES

  belongs_to :family
  belongs_to :forecast_budget_template
  belongs_to :category, optional: true

  monetize :amount

  validates :amount_type, :amount, :currency, presence: true
  validates :amount_type, inclusion: { in: AMOUNT_TYPES }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validate :category_required_for_category_spending
  validate :category_absent_unless_category_spending
  validate :category_must_be_parent_for_category_spending
  validate :associations_belong_to_family
  validate :amount_is_unique_for_template_key

  def amount_key
    [ amount_type, category_id ]
  end

  private
    def category_required_for_category_spending
      return unless amount_type == "category_spending"
      return if category.present?

      errors.add(:category, "must be present for category spending forecast budget template amounts")
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

      errors.add(:category, "must be a parent category for forecast budget templates")
    end

    def associations_belong_to_family
      if forecast_budget_template.present? && forecast_budget_template.family_id != family_id
        errors.add(:forecast_budget_template, "must belong to the forecast family")
      end

      if category.present? && category.family_id != family_id
        errors.add(:category, "must belong to the forecast family")
      end
    end

    def amount_is_unique_for_template_key
      return if forecast_budget_template_id.blank? || amount_type.blank?

      duplicate = self.class
        .where(
          forecast_budget_template_id: forecast_budget_template_id,
          amount_type: amount_type,
          category_id: category_id
        )
      duplicate = duplicate.where.not(id: id) if persisted?
      return unless duplicate.exists?

      errors.add(:base, "forecast budget template amount already exists for this row")
    end
end
