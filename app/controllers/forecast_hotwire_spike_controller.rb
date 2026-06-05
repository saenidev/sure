# frozen_string_literal: true

# THROWAWAY SPIKE — proves disciplined Hotwire (D3/Stimulus local chart scrub +
# scoped Turbo Stream save) can meet the Forecast V2 interaction budgets without
# Inertia/Vite. Delete this controller, its model (ForecastSpike::Plan), views,
# Stimulus controller, routes, and test together.
#
# Reads the family's REAL connected data (balance sheet + income statement,
# read-only, scoped to Current.family) to seed the projection. Edits to the
# cash-flow assumptions are stashed in the session so live recompute survives
# the PATCH round-trip; no DB writes, no V2 schema, no engine.
class ForecastHotwireSpikeController < ApplicationController
  before_action :set_currency

  def show
    @plan = build_plan
    @selected_index = params.fetch(:period_index, ForecastSpike::Plan::MONTHS / 4).to_i
    @breadcrumbs = [ [ "Home", root_path ], [ "Forecast (Hotwire spike)", nil ] ]
  end

  # Scoped save: re-derive the plan with the new assumption value and stream back
  # ONLY the affected regions. The page shell / nav / chat sidebar never reload.
  def update_assumption
    overrides = session[:forecast_spike_overrides] || {}
    overrides[params[:key].to_s] = params[:value]
    session[:forecast_spike_overrides] = overrides

    @plan = build_plan
    @selected_index = params.fetch(:period_index, 0).to_i.clamp(0, ForecastSpike::Plan::MONTHS - 1)
    @edited_card = @plan.assumption_cards.find { |c| c[:key].to_s == params[:key].to_s }

    # Render update_assumption.turbo_stream.erb
  end

  # Reset stashed edits back to the live-data seeds.
  def reset
    session.delete(:forecast_spike_overrides)
    redirect_to forecast_hotwire_spike_path
  end

  private

    def set_currency
      @currency_code = Current.family.primary_currency_code
      @currency_symbol = currency_symbol_for(@currency_code)
    end

    def build_plan
      family = Current.family
      bs = family.balance_sheet
      is = family.income_statement

      asset_totals = bs.assets.account_groups.index_by(&:key).transform_values { |g| g.total.to_f }
      cash = asset_totals["depository"].to_f
      portfolio = asset_totals["investment"].to_f + asset_totals["crypto"].to_f
      other = bs.assets.total.to_f - cash - portfolio
      debt = bs.liabilities.total.to_f

      ForecastSpike::Plan.new(
        opening: { cash: cash, portfolio: portfolio, other_assets: other, debt: debt },
        seeds: {
          income_monthly: amount_of(is.median_income(interval: "month")),
          spending_monthly: amount_of(is.median_expense(interval: "month")),
          debt_payment_monthly: debt.positive? ? (debt * 0.02) : 0.0
        },
        overrides: session[:forecast_spike_overrides] || {},
        currency: @currency_symbol
      )
    end

    def amount_of(value)
      return 0.0 if value.nil?
      return value.to_f if value.is_a?(Numeric)
      return value.amount.to_f if value.respond_to?(:amount)
      value.respond_to?(:to_f) ? value.to_f : 0.0
    end

    def currency_symbol_for(code)
      Money::Currency.new(code).symbol.presence || "$"
    rescue StandardError
      "$"
    end
end
