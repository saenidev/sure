module Forecast
  # Browse + apply the frozen scenario-template catalog. Inherits the
  # family-scoped base controller; applying a template never trusts a
  # params-supplied family. The Applier scopes everything to Current.family and
  # sets created_by_user server-side, so a user can only ever instantiate a
  # template into their OWN family.
  class TemplatesController < BaseController
    # GET /forecast/templates
    # Lists the frozen catalog (stable declaration order) for browsing/applying.
    def index
      @templates = Forecast::ScenarioTemplate.all
    end

    # POST /forecast/templates
    # Applies the chosen template. The Applier validates params and raises
    # InvalidParams BEFORE any write (so an invalid apply creates nothing and is
    # fully rolled back), scopes the created scenario + its events/goals to
    # Current.family, and records template provenance. On bad params (or an
    # unknown template key) we re-render the browse surface at 422 with the
    # resolved error messages and the rejected key/params so the form repopulates.
    def create
      scenario = Forecast::ScenarioTemplate::Applier.apply!(
        template_key: params[:template_key],
        family: Current.family,
        user: Current.user,
        params: template_params
      )

      redirect_to forecast_scenarios_path, notice: t(".success", name: scenario.name)
    rescue Forecast::ScenarioTemplate::InvalidParams => e
      @templates = Forecast::ScenarioTemplate.all
      @errors = e.errors
      @rejected_template_key = params[:template_key].to_s
      @rejected_params = template_params
      render :index, status: :unprocessable_entity
    end

    private
      # Per-template inputs are namespaced under `template_params`. We never
      # permit a family_id/user_id here; the Applier sets the family/user
      # server-side. `to_unsafe_h` is safe because the template's own ParamSpecs
      # coerce + validate every value before any write, and only declared keys
      # are read by the builder.
      def template_params
        params.fetch(:template_params, {}).to_unsafe_h
      end
  end
end
