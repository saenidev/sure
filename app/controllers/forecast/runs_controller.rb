module Forecast
  # Triggers and reports on forecast generation runs. Inherits the family-scoped
  # base controller, so every lookup goes through `Current.family` and a
  # cross-family run-group id raises RecordNotFound (-> 404).
  class RunsController < BaseController
    before_action :set_run_group, only: :status

    # POST /forecast/runs
    # Enqueues a baseline forecast generation off the request path. The actual
    # Runner (90 days + 36 months + projections) never runs inline here.
    def create
      if generation_in_flight?
        redirect_to forecast_path, alert: t("forecasts.runs.already_running")
        return
      end

      ForecastGenerationJob.perform_later(
        family: @family,
        user: Current.user,
        name: t("forecasts.runs.default_name", date: l(Date.current, format: :long))
      )

      redirect_to forecast_path, notice: t("forecasts.runs.enqueued")
    end

    # GET /forecast/runs/:id/status
    # Lightweight liveness endpoint the poller hits while a generation is in
    # flight. Scoped to the current family via set_run_group; another family's
    # id is a 404. Once the group reaches a terminal state we ask the poller to
    # reload the workspace so the user sees the result (or failure) immediately.
    def status
      respond_to do |format|
        format.json do
          render json: {
            id: @run_group.id,
            status: @run_group.status,
            done: @run_group.completed? || @run_group.failed?
          }
        end
      end
    end

    private
      # Block a second generation while one is pending or running for this
      # family, so we never stack duplicate runs.
      def generation_in_flight?
        @family.forecast_run_groups.where(status: %w[pending running]).exists?
      end
  end
end
