class ForecastsController < ApplicationController
  def show
    load_workspace
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("forecasts.workspace.title"), nil ] ]
  end

  # Everything forecasts/show renders from. Public so Forecast::RunsController
  # can re-render the workspace for a rejected run without duplicating it.
  def self.workspace_assigns(family:, today: Date.current)
    loader = Forecasts::WorkspaceLoader.new(family: family, today: today).load
    plan = loader.plan
    cache = loader.cache
    groups = assumption_groups_for(plan)
    derived_count =
      if loader.bootstrapped?
        groups.values.sum { |list| list.count { |a| a.origin == "source_derived" } }
      else
        0
      end

    {
      plan: plan,
      cache: cache,
      island: Forecasts::WorkspaceIsland.from_cache(plan: plan, cache: cache),
      groups: groups,
      derived_count: derived_count,
      issues: (cache.issue_summary || {}).fetch("codes", {})
    }
  end

  # Cards grouped for the rail, in registry order. Kind -> group mapping lives
  # on the island read model so client and server agree.
  def self.assumption_groups_for(plan)
    plan.forecast_assumptions
      .where.not(status: %w[disabled archived])
      .order(:created_at)
      .group_by { |a| Forecasts::WorkspaceIsland::GROUP_FOR_KIND.fetch(a.kind, "other") }
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
    def load_workspace
      self.class.workspace_assigns(family: Current.family).each do |name, value|
        instance_variable_set("@#{name}", value)
      end
    end
end
