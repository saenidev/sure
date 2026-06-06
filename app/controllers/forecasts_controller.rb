class ForecastsController < ApplicationController
  # /forecast is gated behind a feature CHECK, not a separate mounted route.
  #
  # Why a feature check (and not a `/forecast_v2` mount): the spec ("V1
  # Coexistence", "Feature Flags And Release Control", and the Stage C note)
  # wants V2 to ship behind explicit release controls AT the canonical
  # `/forecast` URL, so we can flip a family/user between V1 and V2 without moving
  # the route, breaking deep links, or shipping a second nav entry. A separate
  # mount would fork bookmarks/nav and turn cutover into a URL migration instead
  # of a flag flip. So #show keeps ONE route and branches on Forecasts::V2Flag:
  # flag off -> the untouched V1 Forecast::Workspace path (V1 stays default for
  # everyone else); flag on -> the V2 path (fleshed out in slice C2+).
  #
  # The branch only DECIDES which surface to render; it does not read or mutate
  # any V1 (forecast_run_groups/runs/days/months) or V2 record itself.
  def show
    if forecast_v2_enabled?
      render_forecast_v2
    else
      render_forecast_v1
    end
  end

  # Lazy-loaded panel body for a single workspace tab. The show page renders only
  # the active tab eagerly; every other tab is a lazy Turbo Frame that fetches its
  # body here when first shown, so one /forecast load no longer renders all nine
  # panels (and their builders) server-side at once. Scoped to Current.family and
  # the tab allowlist (ForecastsHelper::TAB_PARTIALS), so no untrusted id reaches
  # the render path. Legacy tab ids are accepted and mapped to the newer grouped
  # decision areas so old links keep working.
  #
  # This is a V1 surface; it is unaffected by the V2 gate above.
  def tab
    @workspace = Forecast::Workspace.new(family: Current.family)
    unless Forecast::Workspace::TAB_IDS.include?(params[:tab_id].to_s) ||
        Forecast::Workspace::TAB_ALIASES.key?(params[:tab_id].to_s)
      return head(:not_found)
    end

    @tab_id = @workspace.canonical_tab_id(params[:tab_id])
    render layout: false
  end

  private
    def forecast_v2_enabled?
      Forecasts::V2Flag.enabled_for?(family: Current.family, user: Current.user)
    end

    # Unchanged V1 path: the existing Forecast::Workspace ERB/Turbo surface.
    def render_forecast_v1
      @workspace = Forecast::Workspace.new(family: Current.family)
      @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("forecasts.show.title"), nil ] ]
      render :show
    end

    # V2 path. Slice C1 only owns the GATE: it proves the V2 branch is reached and
    # renders a working, family-scoped Inertia surface (the proven Forecast/Spike
    # page) so enabling the flag never leaves a broken screen. Slice C2 replaces
    # this with the real load-or-create plan + cache + first-viewport read-model
    # props on the Forecast/Workspace component. It must NOT touch V1
    # Forecast::Workspace / engine / run-group state.
    def render_forecast_v2
      render inertia: "Forecast/Spike", layout: "forecast_inertia", props: {
        plan: { id: "v2_gate", currency: Current.family.primary_currency_code }
      }
    end
end
