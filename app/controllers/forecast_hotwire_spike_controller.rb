# frozen_string_literal: true

# THROWAWAY SPIKE — proves disciplined Hotwire (D3/Stimulus local chart scrub +
# scoped Turbo Stream save) can meet the Forecast V2 interaction budgets without
# Inertia/Vite. Delete this controller, its model (ForecastSpike::Plan), views,
# Stimulus controller, routes, and test together.
#
# No DB, no V2 schema, no engine. Edits are stashed in the session so the live
# recompute survives the PATCH round-trip.
class ForecastHotwireSpikeController < ApplicationController
  def show
    @plan = build_plan
    @selected_index = params.fetch(:period_index, ForecastSpike::Plan::MONTHS / 4).to_i
    @breadcrumbs = [ [ "Home", root_path ], [ "Forecast (Hotwire spike)", nil ] ]
  end

  # Scoped save: re-derive the plan with the new assumption value and stream back
  # ONLY the affected regions (chart data, metric strip, explanation, the edited
  # card, freshness pill). The page shell / nav / chat sidebar never reload.
  def update_assumption
    overrides = session[:forecast_spike_overrides] || {}
    overrides[params[:key].to_s] = params[:value]
    session[:forecast_spike_overrides] = overrides

    @plan = build_plan
    @selected_index = params.fetch(:period_index, 0).to_i.clamp(0, ForecastSpike::Plan::MONTHS - 1)
    @edited_card = @plan.assumption_cards.find { |c| c[:key].to_s == params[:key].to_s }

    # Render update_assumption.turbo_stream.erb
  end

  # Reset stashed edits — handy while testing.
  def reset
    session.delete(:forecast_spike_overrides)
    redirect_to forecast_hotwire_spike_path
  end

  private

    def build_plan
      ForecastSpike::Plan.new(session[:forecast_spike_overrides] || {})
    end
end
