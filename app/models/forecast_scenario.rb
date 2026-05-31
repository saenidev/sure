class ForecastScenario < ApplicationRecord
  STATUSES = %w[active archived disabled].freeze
  APPROVAL_STATUSES = %w[manual pending approved rejected].freeze

  belongs_to :family
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :parent_scenario, class_name: "ForecastScenario", optional: true

  has_many :forecast_events, dependent: :destroy
  has_many :forecast_budget_overrides, dependent: :destroy
  has_one :forecast_budget_plan, dependent: :destroy
  has_many :forecast_goals, dependent: :destroy
  has_many :forecast_account_liquidity_settings, dependent: :destroy

  scope :active, -> { where(status: "active") }
  scope :ordered, -> { order(:position, :created_at) }

  validates :name, :status, :approval_status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :approval_status, inclusion: { in: APPROVAL_STATUSES }
  validate :date_range_valid
  validate :parent_belongs_to_family
  validate :creator_belongs_to_family

  # `display_order` is the form-facing alias for the `position` column so the
  # scenario form can use the friendlier name without leaking the DB column.
  def display_order
    position
  end

  def display_order=(value)
    self.position = value
  end

  def active?
    status == "active"
  end

  def archived?
    status == "archived"
  end

  def disabled?
    status == "disabled"
  end

  # Deep-copies this scenario and its planning children into a (possibly the
  # same) family. The copy is created with:
  #   - status "disabled" so it is inert until the user toggles it on. The
  #     scenario's OWN "disabled" status is the inertness gate: ScenarioStack
  #     only loads `family.forecast_scenarios.active`, so a disabled copy
  #     projects nothing regardless of its children.
  #   - approval_status reset to "manual" (a copy is user-authored, never an
  #     approved/pending AI artifact).
  #   - parent_scenario pointing at the source so lineage is preserved.
  #   - created_by_user set to the supplied user (server-side, never params).
  #
  # All children are re-scoped to the target family and to the new scenario and
  # created ENABLED (events "planned", goals/overrides "active"), so the moment
  # the user toggles the copy on it actually projects. Disabling children would
  # mean an activated copy projects nothing — the defect this guards against.
  # Active override uniqueness is SCENARIO-scoped, so a new scenario's active
  # overrides can never collide with the source's. Runs inside a transaction so a
  # single invalid child rolls the whole duplicate back, which the controller
  # surfaces as an error rather than a 500/partial copy.
  def duplicate_for_family!(family:, user: nil, name: nil)
    transaction do
      copy = family.forecast_scenarios.create!(
        name: name.presence || "#{self.name} (copy)",
        description: description,
        status: "disabled",
        approval_status: "manual",
        starts_on: starts_on,
        ends_on: ends_on,
        color: color,
        position: position,
        assumptions: assumptions,
        source_metadata: source_metadata,
        parent_scenario: family_id == family.id ? self : nil,
        created_by_user: user
      )

      copy_forecast_events_into(copy, family)
      copy_forecast_budget_overrides_into(copy, family)
      copy_forecast_budget_plan_into(copy, family)
      copy_forecast_goals_into(copy, family)
      copy_forecast_account_liquidity_settings_into(copy, family)

      copy
    end
  end

  private
    def copy_forecast_events_into(copy, family)
      forecast_events.find_each do |event|
        copy.forecast_events.create!(
          family: family,
          account: event.account,
          destination_account: event.destination_account,
          category: event.category,
          name: event.name,
          description: event.description,
          effect_type: event.effect_type,
          behavior: event.behavior,
          amount: event.amount,
          currency: event.currency,
          starts_on: event.starts_on,
          ends_on: event.ends_on,
          recurrence_rule: event.recurrence_rule,
          status: "planned",
          probability_weight: event.probability_weight,
          apply_order: event.apply_order,
          source_metadata: event.source_metadata
        )
      end
    end

    def copy_forecast_budget_overrides_into(copy, family)
      forecast_budget_overrides.find_each do |override|
        copy.forecast_budget_overrides.create!(
          family: family,
          category: override.category,
          period_start_on: override.period_start_on,
          override_type: override.override_type,
          amount: override.amount,
          currency: override.currency,
          status: "active",
          note: override.note,
          source_metadata: override.source_metadata
        )
      end
    end

    def copy_forecast_budget_plan_into(copy, family)
      forecast_budget_plan&.copy_into!(scenario: copy, family: family)
    end

    def copy_forecast_goals_into(copy, family)
      forecast_goals.find_each do |goal|
        copy.forecast_goals.create!(
          family: family,
          name: goal.name,
          goal_type: goal.goal_type,
          target_amount: goal.target_amount,
          currency: goal.currency,
          target_duration_days: goal.target_duration_days,
          target_date: goal.target_date,
          starts_on: goal.starts_on,
          ends_on: goal.ends_on,
          required: goal.required,
          blocking_behavior: goal.blocking_behavior,
          status: "active",
          condition_metadata: goal.condition_metadata
        )
      end
    end

    def copy_forecast_account_liquidity_settings_into(copy, family)
      forecast_account_liquidity_settings.find_each do |setting|
        copy.forecast_account_liquidity_settings.create!(
          family: family,
          account: setting.account,
          liquidity_class: setting.liquidity_class,
          starts_on: setting.starts_on,
          ends_on: setting.ends_on,
          constraints: setting.constraints
        )
      end
    end


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
