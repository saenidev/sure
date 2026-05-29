module Forecast
  # Authoring for the evaluation targets a forecast run is graded against.
  # Inherits the family-scoped base controller, so every lookup goes through
  # `Current.family.forecast_goals`. A cross-family id therefore raises
  # ActiveRecord::RecordNotFound (-> 404) instead of trusting params[:id].
  #
  # Goals carry an optional scenario scope (the model's `forecast_scenario` is
  # optional). The scenario select is pre-filtered to the family's scenarios and
  # the model's `scenario_belongs_to_family` validation is the server-side
  # backstop, so a foreign scenario id is rejected with a 422 rather than
  # silently scoping a goal to another family's scenario.
  class GoalsController < BaseController
    before_action :set_goal, only: %i[edit update destroy]

    # GET /forecast/goals
    # Standalone list of the family's goals with their latest evaluation badges.
    # Reuses the workspace query object so the standalone page and the in-tab
    # Goals panel cannot diverge (single source of grouping/eager-loading).
    def index
      @workspace = Forecast::Workspace.new(family: @family)
    end

    # GET /forecast/goals/new
    def new
      @goal = @family.forecast_goals.new(
        goal_type: "minimum_cash_runway",
        blocking_behavior: "warn",
        status: "active",
        currency: @family.currency
      )
    end

    # POST /forecast/goals
    def create
      @goal = @family.forecast_goals.new(goal_params)

      if @goal.save
        redirect_to forecast_goals_path, notice: t(".success")
      else
        render :new, status: :unprocessable_entity
      end
    end

    # GET /forecast/goals/:id/edit
    def edit
    end

    # PATCH/PUT /forecast/goals/:id
    def update
      if @goal.update(goal_params)
        redirect_to forecast_goals_path, notice: t(".success")
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # DELETE /forecast/goals/:id
    def destroy
      @goal.destroy
      redirect_to forecast_goals_path, notice: t(".success")
    end

    private
      def set_goal
        @goal = @family.forecast_goals.find(params[:id])
      end

      # Strong params: only user-authorable attributes. family_id is NEVER
      # permitted (set server-side via the family association). forecast_scenario_id
      # is permitted but pre-filtered to family scenarios in the form select, with
      # the model's scenario_belongs_to_family validation as the backstop.
      def goal_params
        permitted = params.require(:forecast_goal).permit(
          :name, :goal_type, :target_amount, :currency, :target_duration_days,
          :target_date, :starts_on, :ends_on, :required, :blocking_behavior,
          :status, :forecast_scenario_id
        )

        # Normalize a blank currency to nil so a missing currency reads as absent
        # (the model's presence validation still fires for amount goals) and the
        # money field falls back to the family currency when re-rendering rather
        # than constructing Money::Currency.new("").
        permitted[:currency] = permitted[:currency].presence if permitted.key?(:currency)
        permitted
      end
  end
end
