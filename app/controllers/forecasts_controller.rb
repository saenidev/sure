class ForecastsController < ApplicationController
  def show
    @workspace = Forecast::Workspace.new(family: Current.family)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("forecasts.show.title"), nil ] ]
  end

  # Lazy-loaded panel body for a single workspace tab. The show page renders only
  # the active tab eagerly; every other tab is a lazy Turbo Frame that fetches its
  # body here when first shown, so one /forecast load no longer renders all nine
  # panels (and their builders) server-side at once. Scoped to Current.family and
  # the tab allowlist (ForecastsHelper::TAB_PARTIALS), so no untrusted id reaches
  # the render path. Legacy tab ids are accepted and mapped to the newer grouped
  # decision areas so old links keep working.
  def tab
    @workspace = Forecast::Workspace.new(family: Current.family)
    unless Forecast::Workspace::TAB_IDS.include?(params[:tab_id].to_s) ||
        Forecast::Workspace::TAB_ALIASES.key?(params[:tab_id].to_s)
      return head(:not_found)
    end

    @tab_id = @workspace.canonical_tab_id(params[:tab_id])
    render layout: false
  end
end
