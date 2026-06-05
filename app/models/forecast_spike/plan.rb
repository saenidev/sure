# frozen_string_literal: true

# THROWAWAY SPIKE — delete with the rest of forecast_hotwire_spike.
#
# A self-contained, deterministic mock "plan" that derives a 10-year monthly
# projection FROM a handful of editable assumptions. The point of the spike is
# to prove the Hotwire *interaction substrate* (local chart scrub + scoped
# Turbo Stream save) — NOT the real engine — so the math here is intentionally
# simple and uses plain floats rounded for display. The real Forecast V2 engine
# must use decimal arithmetic and typed packets (see the V2 design spec); none
# of this code is a template for that.
#
# What matters: editing an assumption genuinely re-derives the curve, so "live
# recompute" in the UI is real, not faked.
module ForecastSpike
  class Plan
    START_DATE = Date.new(2026, 6, 1)
    MONTHS = 120

    OPENING = { cash: 25_000.0, portfolio: 75_000.0, debt: 30_000.0 }.freeze
    PORTFOLIO_RETURN_ANNUAL = 0.06
    DEBT_APR = 0.069

    DEFAULTS = {
      salary_monthly: 9_500.0,
      salary_growth_annual: 0.03,
      living_monthly: 5_200.0,
      living_inflation_annual: 0.025,
      rent_monthly: 2_800.0,
      debt_payment_monthly: 600.0
    }.freeze

    # Only salary is wired to an inline editor in the spike; the rest are shown
    # as static cards. Add more here if you want to edit them live too.
    EDITABLE = %i[salary_monthly].freeze

    def initialize(overrides = {})
      @inputs = DEFAULTS.merge(sanitize(overrides))
    end

    attr_reader :inputs

    # [{ key:, label:, index:, metrics: {...}, explanation: [...], active: [...] }]
    def periods
      @periods ||= build_periods
    end

    def period(index)
      i = index.to_i.clamp(0, MONTHS - 1)
      periods[i]
    end

    # Cards for the assumption rail.
    def assumption_cards
      [
        { key: :salary_monthly, kind: "salary", icon: "briefcase",
          name: "Primary salary",
          amount_summary: money(@inputs[:salary_monthly]) + " / mo",
          behavior_summary: "#{pct(@inputs[:salary_growth_annual])} annual growth",
          editable: true, value: @inputs[:salary_monthly].round },
        { key: :living_monthly, kind: "living_expense", icon: "shopping-cart",
          name: "Living expenses",
          amount_summary: money(@inputs[:living_monthly]) + " / mo",
          behavior_summary: "#{pct(@inputs[:living_inflation_annual])} inflation",
          editable: false },
        { key: :rent_monthly, kind: "living_expense", icon: "house",
          name: "Rent",
          amount_summary: money(@inputs[:rent_monthly]) + " / mo",
          behavior_summary: "Fixed monthly",
          editable: false },
        { key: :debt_payment_monthly, kind: "debt_payment", icon: "landmark",
          name: "Debt payment",
          amount_summary: money(@inputs[:debt_payment_monthly]) + " / mo",
          behavior_summary: "#{pct(DEBT_APR)} APR on #{money(OPENING[:debt])}",
          editable: false }
      ]
    end

    METRIC_LABELS = {
      net_worth: "Net worth",
      liquid_cash: "Cash",
      income: "Income",
      spending: "Spending",
      debt_balance: "Debt",
      portfolio_value: "Portfolio",
      runway_days: "Runway"
    }.freeze

    private

      def build_periods
        cash = OPENING[:cash]
        portfolio = OPENING[:portfolio]
        debt = OPENING[:debt]

        Array.new(MONTHS) do |m|
          yf = m / 12.0
          salary  = @inputs[:salary_monthly]  * ((1 + @inputs[:salary_growth_annual])**yf)
          living  = @inputs[:living_monthly]  * ((1 + @inputs[:living_inflation_annual])**yf)
          rent    = @inputs[:rent_monthly]

          debt += debt * (DEBT_APR / 12.0)
          pay = [ debt, @inputs[:debt_payment_monthly] ].min
          debt -= pay

          portfolio += portfolio * (PORTFOLIO_RETURN_ANNUAL / 12.0)

          spending = living + rent
          cash += salary - spending - pay
          net_worth = cash + portfolio - debt
          runway = spending.positive? ? (cash / (spending / 30.0)) : 0.0

          date = START_DATE >> m
          {
            key: date.strftime("%Y-%m"),
            label: date.strftime("%b %Y"),
            index: m,
            metrics: {
              net_worth: net_worth.round,
              liquid_cash: cash.round,
              income: salary.round,
              spending: spending.round,
              debt_balance: debt.round,
              portfolio_value: portfolio.round,
              runway_days: runway.round
            },
            explanation: [
              { kind: "income",  label: "Salary",          amount: salary.round },
              { kind: "expense", label: "Living expenses", amount: -living.round },
              { kind: "expense", label: "Rent",            amount: -rent.round },
              { kind: "debt",    label: "Debt payment",    amount: -pay.round }
            ],
            active: %w[salary_monthly living_monthly rent_monthly debt_payment_monthly]
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
        "$" + n.round.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end

      def pct(n)
        "#{(n * 100).round(1).to_s.chomp('.0')}%"
      end
  end
end
