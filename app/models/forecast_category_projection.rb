class ForecastCategoryProjection < ApplicationRecord
  include Forecast::ImmutableOutput

  SOURCES = %w[budget_inheritance forecast_budget_override actual pending forecast_event recurring forecast_effect].freeze

  belongs_to :forecast_month
  belongs_to :category, optional: true
  belongs_to :parent_category, class_name: "Category", optional: true

  validates :projection_key, :source, :currency, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :projection_key, uniqueness: { scope: %i[forecast_month_id source] }
  validates :projected_spending_low, :projected_spending_expected, :projected_spending_high, numericality: { greater_than_or_equal_to: 0 }
  validate :categories_belong_to_family
  validate :source_snapshot_explains_output

  private
    def source_snapshot_explains_output
      return if source_snapshot.present?

      errors.add(:source_snapshot, "must explain the generated output")
    end

    def categories_belong_to_family
      family_id = forecast_month&.forecast_run&.family_id
      return if family_id.blank?

      if category.present? && category.family_id != family_id
        errors.add(:category, "must belong to the forecast family")
      end

      if parent_category.present? && parent_category.family_id != family_id
        errors.add(:parent_category, "must belong to the forecast family")
      end
    end
end
