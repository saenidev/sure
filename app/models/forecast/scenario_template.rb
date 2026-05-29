# Forecast::ScenarioTemplate is a frozen, deterministic catalog of preset
# life-event scenarios a user can browse and apply. Each template is *pure
# data*: it declares its i18n keys, a small set of parameterizable inputs (with
# types/defaults/validation), and a pure builder that maps validated params to
# a plain plan of planning objects to create (a ForecastScenario plus its
# ForecastEvents/ForecastGoals).
#
# Templates are NOT engine math. They never read the wall clock, a random
# source, or DB row order: every date/amount comes from supplied params, so
# applying the same key + params twice yields identical planning objects. The
# transactional instantiation (family/user scoping, provenance, rollback) lives
# in Forecast::ScenarioTemplate::Applier.
class Forecast::ScenarioTemplate
  # Raised when params fail per-template validation. Carries the i18n-resolved
  # messages so the applier can surface them and roll the whole apply back
  # before any record is written.
  class InvalidParams < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)
      super(@errors.join(", "))
    end
  end

  # A single parameterizable input. `type` drives coercion + base validation;
  # `required` and the optional `validate` proc add per-param rules. Defaults
  # are pure values (never Date.current) so the catalog stays deterministic.
  ParamSpec = Struct.new(:key, :type, :required, :default, :validate, keyword_init: true) do
    def coerce(raw)
      case type
      when :date    then coerce_date(raw)
      when :decimal then coerce_decimal(raw)
      when :integer then coerce_integer(raw)
      when :string  then raw.nil? ? nil : raw.to_s
      else raw
      end
    end

    private
      def coerce_date(raw)
        return raw if raw.is_a?(Date)
        return nil if raw.blank?

        Date.iso8601(raw.to_s)
      rescue ArgumentError, TypeError
        :invalid
      end

      def coerce_decimal(raw)
        return nil if raw.blank? && !raw.is_a?(Numeric)
        return BigDecimal(raw.to_s) if raw.is_a?(Numeric)

        BigDecimal(raw.to_s)
      rescue ArgumentError, TypeError
        :invalid
      end

      def coerce_integer(raw)
        return nil if raw.blank? && !raw.is_a?(Numeric)

        Integer(raw.to_s, 10)
      rescue ArgumentError, TypeError
        :invalid
      end
  end

  attr_reader :key, :param_specs

  def initialize(key:, param_specs:, builder:)
    @key = key.to_s
    @param_specs = param_specs.freeze
    @builder = builder
    freeze
  end

  class << self
    # The catalog is built once and frozen. Order is stable (declaration order)
    # so browse UIs render deterministically.
    def catalog
      @catalog ||= build_catalog.freeze
    end

    def keys
      catalog.keys
    end

    def all
      catalog.values
    end

    def find(key)
      catalog[key.to_s]
    end

    # Lookup that raises rather than returning nil, for callers (the applier)
    # that must fail loudly on an unknown key.
    def find!(key)
      find(key) || raise(InvalidParams, [ I18n.t("forecasts.templates.errors.unknown_template", key: key) ])
    end

    private
      def build_catalog
        registry = {}
        definitions.each do |template|
          registry[template.key] = template
        end
        registry
      end

      def definitions
        [
          country_move,
          job_change,
          income_loss,
          major_purchase,
          market_drawdown,
          liquidity_stress,
          tax_placeholder
        ]
      end

      # --- Preset definitions -------------------------------------------------
      # Each preset declares its params and a pure builder block. The builder
      # receives a coerced+validated params Hash (string keys) and the family
      # currency, and returns a plan Hash: { scenario:, events:, goals: }.
      # Builders use ONLY ForecastEvent::EFFECT_TYPES and
      # ForecastGoal::GOAL_TYPES, never invent new ones.

      def country_move
        new(
          key: "country_move",
          param_specs: [
            ParamSpec.new(key: "move_on", type: :date, required: true),
            ParamSpec.new(key: "moving_cost", type: :decimal, required: true,
              validate: ->(v) { positive?(v) }),
            ParamSpec.new(key: "monthly_cost_delta", type: :decimal, required: false, default: nil,
              validate: ->(v) { v.nil? || positive?(v) })
          ],
          builder: ->(params, currency) {
            events = [
              {
                name: I18n.t("forecasts.templates.country_move.events.relocation_cost"),
                effect_type: "expense",
                amount: params["moving_cost"],
                currency: currency,
                starts_on: params["move_on"]
              }
            ]

            if params["monthly_cost_delta"].present?
              events << {
                name: I18n.t("forecasts.templates.country_move.events.cost_of_living"),
                effect_type: "expense",
                amount: params["monthly_cost_delta"],
                currency: currency,
                starts_on: params["move_on"],
                recurrence_rule: { "frequency" => "monthly", "day_of_month" => params["move_on"].day }
              }
            end

            {
              scenario: {
                name: I18n.t("forecasts.templates.country_move.name"),
                description: I18n.t("forecasts.templates.country_move.description"),
                starts_on: params["move_on"]
              },
              events: events,
              goals: []
            }
          }
        )
      end

      def job_change
        new(
          key: "job_change",
          param_specs: [
            ParamSpec.new(key: "starts_on", type: :date, required: true),
            ParamSpec.new(key: "new_monthly_salary", type: :decimal, required: true,
              validate: ->(v) { positive?(v) }),
            ParamSpec.new(key: "old_monthly_salary", type: :decimal, required: false, default: nil,
              validate: ->(v) { v.nil? || positive?(v) })
          ],
          builder: ->(params, currency) {
            events = [
              {
                name: I18n.t("forecasts.templates.job_change.events.new_salary"),
                effect_type: "income",
                amount: params["new_monthly_salary"],
                currency: currency,
                starts_on: params["starts_on"],
                recurrence_rule: { "frequency" => "monthly", "day_of_month" => params["starts_on"].day }
              }
            ]

            if params["old_monthly_salary"].present?
              events << {
                name: I18n.t("forecasts.templates.job_change.events.ended_salary"),
                effect_type: "expense",
                amount: params["old_monthly_salary"],
                currency: currency,
                starts_on: params["starts_on"],
                recurrence_rule: { "frequency" => "monthly", "day_of_month" => params["starts_on"].day }
              }
            end

            {
              scenario: {
                name: I18n.t("forecasts.templates.job_change.name"),
                description: I18n.t("forecasts.templates.job_change.description"),
                starts_on: params["starts_on"]
              },
              events: events,
              goals: []
            }
          }
        )
      end

      def income_loss
        new(
          key: "income_loss",
          param_specs: [
            ParamSpec.new(key: "starts_on", type: :date, required: true),
            ParamSpec.new(key: "lost_monthly_income", type: :decimal, required: true,
              validate: ->(v) { positive?(v) }),
            ParamSpec.new(key: "ends_on", type: :date, required: false, default: nil),
            ParamSpec.new(key: "runway_floor_days", type: :integer, required: false, default: 90,
              validate: ->(v) { v.nil? || (v.is_a?(Integer) && v.positive?) })
          ],
          builder: ->(params, currency) {
            events = [
              {
                name: I18n.t("forecasts.templates.income_loss.events.lost_income"),
                effect_type: "expense",
                amount: params["lost_monthly_income"],
                currency: currency,
                starts_on: params["starts_on"],
                ends_on: params["ends_on"],
                recurrence_rule: { "frequency" => "monthly", "day_of_month" => params["starts_on"].day }
              }
            ]

            goals = []
            if params["runway_floor_days"].present?
              goals << {
                name: I18n.t("forecasts.templates.income_loss.goals.runway_floor"),
                goal_type: "minimum_cash_runway",
                target_duration_days: params["runway_floor_days"],
                blocking_behavior: "warn",
                starts_on: params["starts_on"]
              }
            end

            {
              scenario: {
                name: I18n.t("forecasts.templates.income_loss.name"),
                description: I18n.t("forecasts.templates.income_loss.description"),
                starts_on: params["starts_on"],
                ends_on: params["ends_on"]
              },
              events: events,
              goals: goals
            }
          }
        )
      end

      def major_purchase
        new(
          key: "major_purchase",
          param_specs: [
            ParamSpec.new(key: "purchase_on", type: :date, required: true),
            ParamSpec.new(key: "purchase_amount", type: :decimal, required: true,
              validate: ->(v) { positive?(v) })
          ],
          builder: ->(params, currency) {
            {
              scenario: {
                name: I18n.t("forecasts.templates.major_purchase.name"),
                description: I18n.t("forecasts.templates.major_purchase.description"),
                starts_on: params["purchase_on"]
              },
              events: [
                {
                  name: I18n.t("forecasts.templates.major_purchase.events.purchase"),
                  effect_type: "expense",
                  amount: params["purchase_amount"],
                  currency: currency,
                  starts_on: params["purchase_on"]
                }
              ],
              goals: []
            }
          }
        )
      end

      def market_drawdown
        new(
          key: "market_drawdown",
          param_specs: [
            ParamSpec.new(key: "starts_on", type: :date, required: true),
            ParamSpec.new(key: "drawdown_pct", type: :decimal, required: true,
              # A drawdown is expressed as a positive percentage 0 < pct <= 100.
              validate: ->(v) { v.is_a?(BigDecimal) && v.positive? && v <= 100 }),
            ParamSpec.new(key: "portfolio_value", type: :decimal, required: true,
              validate: ->(v) { positive?(v) })
          ],
          builder: ->(params, currency) {
            # market_shock effects can be signed; a drawdown is a negative shock
            # to portfolio value of (pct/100 * portfolio_value).
            shock = -(params["drawdown_pct"] / BigDecimal("100") * params["portfolio_value"])

            {
              scenario: {
                name: I18n.t("forecasts.templates.market_drawdown.name"),
                description: I18n.t("forecasts.templates.market_drawdown.description"),
                starts_on: params["starts_on"]
              },
              events: [
                {
                  name: I18n.t("forecasts.templates.market_drawdown.events.shock"),
                  effect_type: "market_shock",
                  amount: shock,
                  currency: currency,
                  starts_on: params["starts_on"]
                }
              ],
              goals: []
            }
          }
        )
      end

      def liquidity_stress
        new(
          key: "liquidity_stress",
          param_specs: [
            ParamSpec.new(key: "starts_on", type: :date, required: true),
            ParamSpec.new(key: "monthly_shortfall", type: :decimal, required: true,
              validate: ->(v) { positive?(v) }),
            ParamSpec.new(key: "ends_on", type: :date, required: false, default: nil),
            ParamSpec.new(key: "liquid_runway_floor_days", type: :integer, required: false, default: 60,
              validate: ->(v) { v.nil? || (v.is_a?(Integer) && v.positive?) })
          ],
          builder: ->(params, currency) {
            events = [
              {
                name: I18n.t("forecasts.templates.liquidity_stress.events.shortfall"),
                effect_type: "expense",
                amount: params["monthly_shortfall"],
                currency: currency,
                starts_on: params["starts_on"],
                ends_on: params["ends_on"],
                recurrence_rule: { "frequency" => "monthly", "day_of_month" => params["starts_on"].day }
              }
            ]

            goals = []
            if params["liquid_runway_floor_days"].present?
              goals << {
                name: I18n.t("forecasts.templates.liquidity_stress.goals.liquid_runway"),
                goal_type: "minimum_liquid_runway",
                target_duration_days: params["liquid_runway_floor_days"],
                blocking_behavior: "warn",
                starts_on: params["starts_on"]
              }
            end

            {
              scenario: {
                name: I18n.t("forecasts.templates.liquidity_stress.name"),
                description: I18n.t("forecasts.templates.liquidity_stress.description"),
                starts_on: params["starts_on"],
                ends_on: params["ends_on"]
              },
              events: events,
              goals: goals
            }
          }
        )
      end

      # A deliberate placeholder: a tax life-event template with no engine-bearing
      # effects yet. It instantiates an editable scenario the user can flesh out,
      # but ships no events/goals so it never asserts unmodeled tax math.
      def tax_placeholder
        new(
          key: "tax_placeholder",
          param_specs: [
            ParamSpec.new(key: "effective_on", type: :date, required: true)
          ],
          builder: ->(params, _currency) {
            {
              scenario: {
                name: I18n.t("forecasts.templates.tax_placeholder.name"),
                description: I18n.t("forecasts.templates.tax_placeholder.description"),
                starts_on: params["effective_on"]
              },
              events: [],
              goals: []
            }
          }
        )
      end

      def positive?(value)
        value.is_a?(BigDecimal) && value.positive?
      end
  end

  # Coerces + validates the supplied raw params, returning a frozen Hash with
  # string keys (coerced values, defaults filled). Raises InvalidParams with
  # i18n-resolved messages on any failure. This is the single validation gate
  # the builder and applier both rely on.
  def sanitize_params(raw_params)
    raw = (raw_params || {}).transform_keys(&:to_s)
    errors = []
    sanitized = {}

    param_specs.each do |spec|
      present = raw.key?(spec.key) && !blankish?(raw[spec.key])
      value = present ? spec.coerce(raw[spec.key]) : spec.default

      if value == :invalid
        errors << error_message(spec.key, :invalid_type)
        next
      end

      if spec.required && blankish?(value)
        errors << error_message(spec.key, :blank)
        next
      end

      if value.present? && spec.validate && !spec.validate.call(value)
        errors << error_message(spec.key, :invalid)
        next
      end

      sanitized[spec.key] = value
    end

    # Cross-field gate: an optional ends_on must not predate starts_on. The
    # per-field loop only coerces/validates each value in isolation, so a
    # chronologically-inverted range would otherwise slip through and only be
    # caught by the child record's create! (an unhandled 500). Catching it here
    # keeps the failure in the deterministic validation gate (a graceful 422).
    starts_on = sanitized["starts_on"]
    ends_on = sanitized["ends_on"]
    if starts_on.is_a?(Date) && ends_on.is_a?(Date) && ends_on < starts_on
      errors << error_message("ends_on", :ends_before_start)
    end

    raise InvalidParams, errors if errors.any?

    sanitized.freeze
  end

  # Pure: maps validated params to a plan Hash of plain attributes. Does not
  # touch the database, the clock, or any RNG. `currency` is supplied by the
  # applier (the family's primary currency) so the builder stays pure.
  def build_plan(raw_params, currency:)
    params = sanitize_params(raw_params)
    @builder.call(params, currency).merge(params: params)
  end

  private
    def blankish?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def error_message(param_key, reason)
      # Resolve a human label for the param (falls back to the raw key) so the
      # generic error templates read naturally, then interpolate it. Prefer a
      # per-template/per-param override, then the shared generic message.
      param_label = I18n.t(
        "forecasts.templates.params.#{param_key}.label",
        default: param_key.to_s.humanize
      )

      I18n.t(
        "forecasts.templates.#{key}.errors.#{param_key}.#{reason}",
        param: param_label,
        default: [
          :"forecasts.templates.errors.#{reason}"
        ]
      )
    end
end
