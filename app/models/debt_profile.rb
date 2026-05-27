class DebtProfile < ApplicationRecord
  STATUSES = %w[active disabled archived].freeze
  RATE_TYPES = %w[fixed variable adjustable promotional].freeze
  CADENCES = %w[daily monthly].freeze

  belongs_to :account

  has_many :debt_rate_periods, dependent: :destroy
  has_many :debt_events, dependent: :nullify
  has_many :debt_obligations, dependent: :nullify
  has_many :debt_payment_allocations, dependent: :nullify
  has_many :debt_posting_runs, dependent: :nullify

  validates :account_id, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :rate_type, inclusion: { in: RATE_TYPES }, allow_blank: true
  validates :accrual_cadence, inclusion: { in: CADENCES }, allow_blank: true
  validates :compounding_cadence, inclusion: { in: CADENCES }, allow_blank: true
  validates :minimum_payment_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :minimum_payment_percent, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :annual_rate, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  validates :grace_period_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :account_must_be_liability
  validate :day_fields_in_range
  validate :effective_dates_ordered

  def active?
    status == "active"
  end

  def annual_rate
    return @annual_rate if defined?(@annual_rate)

    debt_rate_periods.for_date(Date.current).first&.annual_rate
  end

  def annual_rate=(value)
    @annual_rate = value
  end

  private
    def account_must_be_liability
      return if account&.liability?

      errors.add(:account, "must be a liability account")
    end

    def day_fields_in_range
      %i[payment_due_day statement_closing_day].each do |field|
        value = public_send(field)
        next if value.blank?
        next if value.between?(1, 31)

        errors.add(field, "must be between 1 and 31")
      end
    end

    def effective_dates_ordered
      return if effective_start_on.blank? || effective_end_on.blank?
      return if effective_end_on >= effective_start_on

      errors.add(:effective_end_on, "must be on or after effective_start_on")
    end
end
