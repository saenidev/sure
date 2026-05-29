module Forecast
  # Lazy-loads the deterministic sensitivity analysis panel into the workspace
  # via a Turbo Frame. The analysis re-runs Forecast::Engine once per
  # perturbation, so it is deliberately NOT computed on the main workspace page
  # load; the Sensitivity tab renders a placeholder frame that GETs this action,
  # which is the only place the N engine runs happen.
  #
  # Inherits the family-scoped base controller, so the workspace it builds reads
  # only Current.family's runs. No id is trusted from params — the latest
  # completed baseline run is resolved through the family association, so another
  # family's run can never be analyzed here.
  class SensitivityController < BaseController
    # GET /forecast/sensitivity
    def show
      @workspace = Forecast::Workspace.new(family: @family)
    end
  end
end
