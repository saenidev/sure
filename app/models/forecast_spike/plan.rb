# frozen_string_literal: true

# THROWAWAY SPIKE — delete with the rest of forecast_hotwire_spike.
#
# A deterministic projection seeded from the family's REAL connected data:
# opening balances come from the balance sheet (cash / portfolio / other assets /
# debt) and the monthly income & spending seeds come from the income statement.
# The user can then edit the cash-flow assumptions and watch the curve recompute.
#
# The point of the spike is the Hotwire *interaction substrate* (local chart
# scrub + scoped Turbo Stream save) — NOT the real engine — so the math is
# intentionally simple (plain floats rounded for display). The real Forecast V2
# engine must use decimal arithmetic and typed packets; none of this is a
# template for that.
module ForecastSpike
  class Plan
    START_DATE = Date.new(2026, 6, 1)
    MONTHS = 120

    PORTFOLIO_RETURN_ANNUAL = 0.06
    DEBT_APR = 0.069
    INCOME_GROWTH_ANNUAL = 0.03
    SPENDING_INFLATION_ANNUAL = 0.025

    OPENING_DEFAULTS = { cash: 0.0, portfolio: 0.0, other_assets: 0.0, debt: 0.0 }.freeze
    SEED_DEFAULTS = { income_monthly: 0.0, spending_monthly: 0.0, debt_payment_monthly: 0.0 }.freeze
    EDITABLE = %i[income_monthly spending_monthly debt_payment_monthly].freeze

    METRIC_LABELS = {
      net_worth: "Net worth",
      liquid_cash: "Cash",
      income: "Income",
      spending: "Spending",
      debt_balance: "Debt",
      portfolio_value: "Portfolio",
      runway_days: "Runway"
    }.freeze

    def initialize(opening: {}, seeds: {}, overrides: {}, currency: "$")
      @opening = OPENING_DEFAULTS.merge(opening.slice(*OPENING_DEFAULTS.keys))
      @seeds = SEED_DEFAULTS.merge(seeds.slice(*SEED_DEFAULTS.keys)).merge(sanitize(overrides))
      @currency = currency
    end

    attr_reader :opening, :seeds

    def periods
      @periods ||= build_periods
    end

    def period(index)
      periods[index.to_i.clamp(0, MONTHS - 1)]
    end

    def opening_summary
      net_worth = @opening[:cash] + @opening[:portfolio] + @opening[:other_assets] - @opening[:debt]
      @opening.merge(net_worth: net_worth)
    end

    def assumption_cards
      [
        { key: :income_monthly, kind: "income", icon: "trending-up",
          name: "Monthly income",
          amount_summary: "#{money(@seeds[:income_monthly])} / mo",
          behavior_summary: "#{pct(INCOME_GROWTH_ANNUAL)} annual growth",
          editable: true, value: @seeds[:income_monthly].round },
        { key: :spending_monthly, kind: "spending", icon: "shopping-cart",
          name: "Monthly spending",
          amount_summary: "#{money(@seeds[:spending_monthly])} / mo",
          behavior_summary: "#{pct(SPENDING_INFLATION_ANNUAL)} inflation",
          editable: true, value: @seeds[:spending_monthly].round },
        { key: :debt_payment_monthly, kind: "debt_payment", icon: "landmark",
          name: "Debt payment",
          amount_summary: "#{money(@seeds[:debt_payment_monthly])} / mo",
          behavior_summary: "#{pct(DEBT_APR)} APR on opening debt",
          editable: true, value: @seeds[:debt_payment_monthly].round }
      ]
    end

    private

      def build_periods
        cash = @opening[:cash]
        portfolio = @opening[:portfolio]
        debt = @opening[:debt]
        other = @opening[:other_assets]

        Array.new(MONTHS) do |m|
          yf = m / 12.0
          income   = @seeds[:income_monthly]   * ((1 + INCOME_GROWTH_ANNUAL)**yf)
          spending = @seeds[:spending_monthly] * ((1 + SPENDING_INFLATION_ANNUAL)**yf)

          debt += debt * (DEBT_APR / 12.0)
          pay = [ debt, @seeds[:debt_payment_monthly] ].min
          debt -= pay

          portfolio += portfolio * (PORTFOLIO_RETURN_ANNUAL / 12.0)

          cash += income - spending - pay
          net_worth = cash + portfolio + other - debt
          runway = spending.positive? ? (cash / (spending / 30.0)) : 0.0

          date = START_DATE >> m
          {
            key: date.strftime("%Y-%m"),
            label: date.strftime("%b %Y"),
            index: m,
            metrics: {
              net_worth: net_worth.round,
              liquid_cash: cash.round,
              income: income.round,
              spending: spending.round,
              debt_balance: debt.round,
              portfolio_value: portfolio.round,
              runway_days: runway.round
            },
            explanation: [
              { kind: "income",  label: "Income",       amount: income.round },
              { kind: "expense", label: "Spending",     amount: -spending.round },
              { kind: "debt",    label: "Debt payment", amount: -pay.round }
            ]
          }
        end
      end

      def sanitize(overrides)
        (overrides || {}).each_with_object({}) do |(k, v), acc|
          key = k.to_sym
          next unless EDITABLE.include?(key)
          num = v.to_f
          acc[key] = num if num.positive?
        end
      end

      def money(n)
        sign = n.negative? ? "-" : ""
        "#{sign}#{@currency}#{n.abs.round.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
      end

      def pct(n)
        "#{(n * 100).round(1).to_s.chomp('.0')}%"
      end
  end
end
