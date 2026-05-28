class ForecastEvent < ApplicationRecord
  include Monetizable

  EFFECT_TYPES = %w[
    income expense transfer debt_drawdown debt_payment debt_interest
    portfolio_contribution portfolio_withdrawal market_shock
  ].freeze
  AMOUNT_EFFECT_TYPES = %w[
    income expense transfer debt_drawdown debt_payment debt_interest
    portfolio_contribution portfolio_withdrawal market_shock
  ].freeze
  DIRECTIONAL_AMOUNT_EFFECT_TYPES = AMOUNT_EFFECT_TYPES - %w[market_shock]
  BEHAVIORS = %w[additive].freeze
  STATUSES = %w[planned accepted ignored disabled].freeze

  belongs_to :family
  belongs_to :forecast_scenario, optional: true
  belongs_to :account, optional: true
  belongs_to :destination_account, class_name: "Account", optional: true
  belongs_to :category, optional: true

  has_many :forecast_event_links, dependent: :nullify

  monetize :amount, allow_nil: true

  validates :name, :effect_type, :behavior, :starts_on, :status, presence: true
  validates :effect_type, inclusion: { in: EFFECT_TYPES }
  validates :behavior, inclusion: { in: BEHAVIORS }
  validates :status, inclusion: { in: STATUSES }
  validates :amount, numericality: true, allow_nil: true
  validates :probability_weight, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :currency, presence: true, if: -> { amount.present? }
  validate :date_range_valid
  validate :associations_belong_to_family
  validate :amount_required_for_amount_effects
  validate :directional_amounts_are_positive
  validate :transfer_has_accounts
  validate :cross_currency_transfer_has_destination_amount
  validate :recurrence_rule_supported

  def recurring?
    recurrence_rule.present?
  end

  private
    def date_range_valid
      return if ends_on.blank? || starts_on.blank? || ends_on >= starts_on

      errors.add(:ends_on, "must be on or after starts_on")
    end

    def associations_belong_to_family
      validate_family_match(forecast_scenario, :forecast_scenario)
      validate_family_match(account, :account)
      validate_family_match(destination_account, :destination_account)
      validate_family_match(category, :category)
    end

    def validate_family_match(record, attribute)
      return if record.blank? || record.family_id == family_id

      errors.add(attribute, "must belong to the forecast family")
    end

    def amount_required_for_amount_effects
      return unless effect_type.in?(AMOUNT_EFFECT_TYPES)
      return if amount.present?

      errors.add(:amount, "must be present for amount-based forecast events")
    end

    def directional_amounts_are_positive
      return unless effect_type.in?(DIRECTIONAL_AMOUNT_EFFECT_TYPES)
      return if amount.blank? || amount.to_d.positive?

      errors.add(:amount, "must be greater than 0 for directional forecast events")
    end

    def transfer_has_accounts
      return unless effect_type == "transfer"

      errors.add(:account, "must be present for transfer events") if account.blank?
      errors.add(:destination_account, "must be present for transfer events") if destination_account.blank?
    end

    def cross_currency_transfer_has_destination_amount
      return unless effect_type == "transfer"
      return if account.blank? || destination_account.blank?
      return if account.currency == destination_account.currency
      return if source_metadata["destination_amount"].present? && source_metadata["destination_currency"].present?

      errors.add(:source_metadata, "must include destination_amount and destination_currency for cross-currency transfer events")
    end

    def recurrence_rule_supported
      return if recurrence_rule.blank?
      unless recurrence_rule.respond_to?(:fetch)
        errors.add(:recurrence_rule, "must be an object")
        return
      end

      frequency = recurrence_rule.fetch("frequency", "monthly")
      errors.add(:recurrence_rule, "frequency must be weekly or monthly") unless frequency.in?(%w[weekly monthly])

      interval = recurrence_rule.fetch("interval", 1).to_i
      errors.add(:recurrence_rule, "interval must be between 1 and 60") unless interval.between?(1, 60)

      return unless frequency == "monthly"

      day_of_month = recurrence_rule.fetch("day_of_month", starts_on&.day || 1).to_i
      errors.add(:recurrence_rule, "day_of_month must be between 1 and 31") unless day_of_month.between?(1, 31)
    end
end
