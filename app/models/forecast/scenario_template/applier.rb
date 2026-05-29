# Forecast::ScenarioTemplate::Applier turns a preset template + user-supplied
# params into a NORMAL, editable ForecastScenario (plus its ForecastEvents and
# ForecastGoals) for a family/user. It mirrors the proven
# ForecastScenario#duplicate_for_family! shape:
#
#   - everything runs inside a single transaction, so one invalid child rolls
#     the WHOLE apply back (no partial scenario);
#   - the scenario and children are scoped to the *passed* family (never a
#     params-supplied family_id), and created_by_user is set server-side;
#   - provenance is recorded in source_metadata as
#       {"source" => "template", "template_key" => key, "params" => sanitized}
#     with approval_status "manual" (template output is user-authored planning,
#     never an approved/pending AI artifact).
#
# Determinism/immutability: applying a template only creates editable planning
# objects. It NEVER reads, creates, or mutates any ForecastRun/ForecastMonth
# output, and reads no wall clock — every date comes from the supplied params.
class Forecast::ScenarioTemplate::Applier
  # Newly applied scenarios are inert ("disabled") until the user toggles them
  # on, mirroring duplicate_for_family! so the per-period active-uniqueness on
  # any future overrides cannot collide and so a freshly-applied template does
  # not silently alter the next projection.
  SCENARIO_STATUS = "disabled"
  EVENT_STATUS = "planned"
  GOAL_STATUS = "active"

  attr_reader :template, :family, :user, :raw_params

  def initialize(template_key:, family:, user: nil, params: {})
    @template = Forecast::ScenarioTemplate.find!(template_key)
    @family = family
    @user = user
    @raw_params = params || {}
  end

  # Convenience entry point.
  def self.apply!(template_key:, family:, user: nil, params: {})
    new(template_key: template_key, family: family, user: user, params: params).apply!
  end

  # Builds the plan (validates params, raising InvalidParams before any write)
  # then instantiates the scenario + children in one transaction. Returns the
  # created ForecastScenario. Raises:
  #   - Forecast::ScenarioTemplate::InvalidParams  on bad params (no write);
  #   - ActiveRecord::RecordInvalid                on an invalid child (rollback).
  def apply!
    plan = template.build_plan(raw_params, currency: family.primary_currency_code)
    sanitized_params = plan.fetch(:params)

    ForecastScenario.transaction do
      scenario = create_scenario(plan.fetch(:scenario), sanitized_params)
      create_events(scenario, plan.fetch(:events))
      create_goals(scenario, plan.fetch(:goals))
      scenario
    end
  end

  private
    def create_scenario(attrs, sanitized_params)
      family.forecast_scenarios.create!(
        name: attrs.fetch(:name),
        description: attrs[:description],
        status: SCENARIO_STATUS,
        approval_status: "manual",
        starts_on: attrs[:starts_on],
        ends_on: attrs[:ends_on],
        color: attrs[:color],
        created_by_user: user,
        source_metadata: {
          "source" => "template",
          "template_key" => template.key,
          "params" => serialize_params(sanitized_params)
        }
      )
    end

    def create_events(scenario, events)
      events.each do |attrs|
        scenario.forecast_events.create!(
          family: family,
          name: attrs.fetch(:name),
          description: attrs[:description],
          effect_type: attrs.fetch(:effect_type),
          behavior: "additive",
          amount: attrs[:amount],
          currency: attrs[:currency],
          starts_on: attrs.fetch(:starts_on),
          ends_on: attrs[:ends_on],
          recurrence_rule: attrs[:recurrence_rule] || {},
          status: EVENT_STATUS,
          source_metadata: {
            "source" => "template",
            "template_key" => template.key
          }
        )
      end
    end

    def create_goals(scenario, goals)
      goals.each do |attrs|
        scenario.forecast_goals.create!(
          family: family,
          name: attrs.fetch(:name),
          goal_type: attrs.fetch(:goal_type),
          target_amount: attrs[:target_amount],
          currency: attrs[:currency],
          target_duration_days: attrs[:target_duration_days],
          target_date: attrs[:target_date],
          starts_on: attrs[:starts_on],
          ends_on: attrs[:ends_on],
          blocking_behavior: attrs[:blocking_behavior] || "warn",
          status: GOAL_STATUS,
          condition_metadata: {
            "source" => "template",
            "template_key" => template.key
          }
        )
      end
    end

    # JSON-safe param serialization: Dates -> ISO strings, BigDecimals ->
    # canonical strings, so the stored provenance round-trips deterministically
    # and never carries Ruby objects jsonb cannot represent.
    def serialize_params(params)
      params.transform_values do |value|
        case value
        when Date       then value.iso8601
        when BigDecimal then value.to_s("F")
        else value
        end
      end
    end
end
