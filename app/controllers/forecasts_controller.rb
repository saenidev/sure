class ForecastsController < ApplicationController
  def show
    @workspace = Forecast::Workspace.new(family: Current.family)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("forecasts.show.title"), nil ] ]
  end
end
