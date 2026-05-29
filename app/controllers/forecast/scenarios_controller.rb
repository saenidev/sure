module Forecast
  # Manual scenario management: the planning layer that feeds forecast runs.
  # Inherits the family-scoped base controller, so every lookup goes through
  # `Current.family.forecast_scenarios`. A cross-family id therefore raises
  # ActiveRecord::RecordNotFound (-> 404) instead of trusting params[:id].
  class ScenariosController < BaseController
    before_action :set_scenario, only: %i[edit update destroy toggle duplicate]

    # GET /forecast/scenarios
    # Lists the family's scenarios grouped by status. Reuses the workspace query
    # object so the grouping/eager-loading lives in one place (fat model) and the
    # standalone page and the in-workspace Scenarios tab cannot diverge.
    def index
      @scenario_groups = Forecast::Workspace.new(family: @family).scenario_groups
    end

    # GET /forecast/scenarios/new
    def new
      @scenario = @family.forecast_scenarios.new(status: "active")
    end

    # POST /forecast/scenarios
    def create
      @scenario = @family.forecast_scenarios.new(scenario_params)
      @scenario.created_by_user = Current.user

      if @scenario.save
        redirect_to forecast_scenarios_path, notice: t(".success")
      else
        render :new, status: :unprocessable_entity
      end
    end

    # GET /forecast/scenarios/:id/edit
    def edit
    end

    # PATCH/PUT /forecast/scenarios/:id
    def update
      if @scenario.update(scenario_params)
        redirect_to forecast_scenarios_path, notice: t(".success")
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # DELETE /forecast/scenarios/:id
    def destroy
      @scenario.destroy
      redirect_to forecast_scenarios_path, notice: t(".success")
    end

    # PATCH /forecast/scenarios/:id/toggle
    # Flips an active<->disabled scenario. Never deletes. Archived scenarios are
    # not toggleable (they are a terminal, opt-in state) so the toggle is a
    # no-op with a clear message rather than silently reactivating archived data.
    def toggle
      if @scenario.archived?
        respond_to do |format|
          format.turbo_stream { render_scenario_row(status: :unprocessable_entity) }
          format.html { redirect_to forecast_scenarios_path, alert: t(".archived") }
        end
        return
      end

      new_status = @scenario.active? ? "disabled" : "active"

      if @scenario.update(status: new_status)
        respond_to do |format|
          format.turbo_stream { render_scenario_row }
          format.html { redirect_to forecast_scenarios_path, notice: t(".success") }
        end
      else
        respond_to do |format|
          format.turbo_stream { render_scenario_row(status: :unprocessable_entity) }
          format.html { redirect_to forecast_scenarios_path, alert: t(".error") }
        end
      end
    end

    # POST /forecast/scenarios/:id/duplicate
    # Deep-copies the scenario and its planning children into the current family.
    # The copy is created disabled + approval_status manual, so it is inert and
    # cannot collide with the source's active budget overrides. A validation
    # failure on any child rolls the whole copy back and surfaces an error rather
    # than a 500.
    def duplicate
      @scenario.duplicate_for_family!(family: @family, user: Current.user)
      redirect_to forecast_scenarios_path, notice: t(".success")
    rescue ActiveRecord::RecordInvalid => e
      redirect_to forecast_scenarios_path, alert: t(".error", message: e.record.errors.full_messages.to_sentence)
    end

    private
      def set_scenario
        @scenario = @family.forecast_scenarios.find(params[:id])
      end

      # Strong params: only user-authorable attributes. family_id and
      # created_by_user_id are NEVER permitted; they are set server-side to
      # Current.family / Current.user. `display_order` is the form-facing alias
      # for the `position` column (ForecastScenario#display_order=).
      def scenario_params
        params.require(:forecast_scenario).permit(
          :name, :description, :starts_on, :ends_on, :display_order, :status
        )
      end

      # Re-render just this scenario's row into the turbo-frame list. Used by
      # toggle so the list updates in place without a full reload. A failed/no-op
      # toggle re-renders the same (unchanged) row so the toggle snaps back.
      def render_scenario_row(status: :ok)
        render(
          turbo_stream: turbo_stream.replace(
            ActionView::RecordIdentifier.dom_id(@scenario),
            partial: "forecast/scenarios/scenario_row",
            locals: { scenario: @scenario }
          ),
          status: status
        )
      end
  end
end
