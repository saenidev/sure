module Forecast
  # Authoring for the dated effects that drive scenarios. Inherits the
  # family-scoped base controller, so every lookup goes through
  # `Current.family.forecast_events`. A cross-family id therefore raises
  # ActiveRecord::RecordNotFound (-> 404) instead of trusting params[:id].
  #
  # Events are optionally nested under a scenario (the model's
  # `forecast_scenario` is optional), so the form can author either a
  # scenario-scoped or a family-level event. The owning scenario is resolved
  # through the family association so a foreign scenario id is rejected.
  class EventsController < BaseController
    before_action :set_scenario, only: %i[index new create]
    before_action :set_event, only: %i[edit update destroy]

    # GET /forecast/events
    # Flat list of the family's events (optionally filtered to one scenario).
    # Eager-loads the associations every row renders so the list never N+1s
    # over account/destination/category/scenario.
    def index
      @events = scoped_events
        .includes(:account, :destination_account, :category, :forecast_scenario)
        .order(starts_on: :desc, created_at: :desc)
        .to_a
    end

    # GET /forecast/events/new
    def new
      @event = @family.forecast_events.new(
        effect_type: "expense",
        behavior: "additive",
        status: "planned",
        currency: @family.currency,
        starts_on: Date.current,
        forecast_scenario: @scenario,
        probability_weight: 1.0
      )
    end

    # POST /forecast/events
    def create
      @event = @family.forecast_events.new(event_params)
      @event.behavior = "additive" # behavior is fixed; never user-settable.

      if @event.save
        redirect_to after_save_path, notice: t(".success")
      else
        render :new, status: :unprocessable_entity
      end
    end

    # GET /forecast/events/:id/edit
    def edit
    end

    # PATCH/PUT /forecast/events/:id
    def update
      if @event.update(event_params.merge(behavior: "additive"))
        redirect_to after_save_path, notice: t(".success")
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # DELETE /forecast/events/:id
    def destroy
      @event.destroy
      redirect_to after_save_path, notice: t(".success")
    end

    private
      # Optional owning scenario, resolved through the family association so a
      # foreign scenario id is a 404 rather than a way to author into another
      # family's scenario.
      def set_scenario
        return if params[:scenario_id].blank?

        @scenario = @family.forecast_scenarios.find(params[:scenario_id])
      end

      def set_event
        @event = @family.forecast_events.find(params[:id])
        @scenario = @event.forecast_scenario
      end

      def scoped_events
        @scenario ? @scenario.forecast_events : @family.forecast_events
      end

      # Strong params: only model-safe, user-authorable attributes. family_id is
      # NEVER permitted (set server-side via the family association); behavior is
      # forced to "additive" in the actions. forecast_scenario_id, account_id,
      # destination_account_id and category_id are permitted but pre-filtered to
      # the family in the form selects, and the model's
      # associations_belong_to_family is the server-side backstop.
      def event_params
        permitted = params.require(:forecast_event).permit(
          :name, :description, :effect_type, :amount, :currency,
          :starts_on, :ends_on, :status, :probability_weight,
          :forecast_scenario_id, :account_id, :destination_account_id, :category_id,
          :recurring, recurrence_rule: %i[frequency interval day_of_month],
          source_metadata: %i[destination_amount destination_currency]
        )

        normalize_recurrence(permitted)
        normalize_source_metadata(permitted)
        permitted
      end

      # The form sends a `recurring` checkbox plus a nested recurrence_rule. When
      # the box is off (one-time event) we drop the rule entirely so the model
      # stores `{}` (recurring? == false). When on, we keep only the supported
      # keys and coerce the numerics, producing the JSON shape the model
      # validates (frequency weekly/monthly, interval 1-60, day_of_month 1-31).
      def normalize_recurrence(permitted)
        recurring = ActiveModel::Type::Boolean.new.cast(permitted.delete(:recurring))
        rule = permitted[:recurrence_rule]

        unless recurring && rule.present?
          permitted[:recurrence_rule] = {}
          return
        end

        cleaned = { "frequency" => rule[:frequency].presence || "monthly" }
        cleaned["interval"] = rule[:interval].to_i if rule[:interval].present?
        if cleaned["frequency"] == "monthly" && rule[:day_of_month].present?
          cleaned["day_of_month"] = rule[:day_of_month].to_i
        end
        permitted[:recurrence_rule] = cleaned
      end

      # Only carry cross-currency destination metadata when both halves are
      # provided; otherwise persist `{}` so the model's same-currency path is
      # used and a half-filled pair cannot masquerade as a valid transfer.
      def normalize_source_metadata(permitted)
        metadata = permitted[:source_metadata]
        return permitted[:source_metadata] = {} if metadata.blank?

        amount = metadata[:destination_amount]
        currency = metadata[:destination_currency]

        if amount.present? && currency.present?
          permitted[:source_metadata] = {
            "destination_amount" => amount,
            "destination_currency" => currency
          }
        else
          permitted[:source_metadata] = {}
        end
      end

      def after_save_path
        if @scenario
          forecast_events_path(scenario_id: @scenario.id)
        else
          forecast_events_path
        end
      end
  end
end
