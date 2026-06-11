class ForecastsController < ApplicationController
  def show
    loader = Forecasts::WorkspaceLoader.new(family: Current.family, today: Date.current).load
    @plan = loader.plan
    @cache = loader.cache
    @island = Forecasts::WorkspaceIsland.from_cache(plan: @plan, cache: @cache)
    @groups = assumption_groups
    @derived_count =
      if loader.bootstrapped?
        @groups.values.sum { |list| list.count { |a| a.origin == "source_derived" } }
      else
        0
      end
    @issues = (@cache.issue_summary || {}).fetch("codes", {})
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("forecasts.workspace.title"), nil ] ]
  end

  # V1 lazy tab endpoint — still routable until the phase-9 cutover. Unchanged.
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
    # Cards grouped for the rail, in registry order. Kind -> group mapping lives
    # on the island read model so client and server agree.
    def assumption_groups
      @plan.forecast_assumptions
        .where.not(status: %w[disabled archived])
        .order(:created_at)
        .group_by { |a| Forecasts::WorkspaceIsland::GROUP_FOR_KIND.fetch(a.kind, "other") }
    end
end
