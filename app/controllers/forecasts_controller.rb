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
  # the render path.
  def tab
    @tab_id = params[:tab_id]
    return head(:not_found) unless ForecastsHelper::TAB_PARTIALS.key?(@tab_id)

    @workspace = Forecast::Workspace.new(family: Current.family)
    render layout: false
  end
end
