# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module Forecasts
  module Projection
    # Pure value object for one period's computed metrics. Money metrics are
    # carried as fixed-precision decimal strings (never floats); `runway_days` is
    # an integer count of days of liquidity. The simulator builds these from
    # running decimal balances and the period's flow sums. See spec "Period
    # Simulation", "Projection Result", and "Currency And Rounding".
    class Metrics
      # Display/persistence precision: two minor units. Rounding for ledger
      # persistence and snapshot output is deterministic (half-up) and documented
      # by currency minor units per the spec.
      MONEY_PRECISION = 2

      # The metric keys every period row exposes, in display order.
      MONEY_KEYS = %i[net_worth liquid_cash income spending debt_balance portfolio_value].freeze

      attr_reader :currency

      # All money arguments are BigDecimal; `runway_days` is an Integer.
      def initialize(net_worth:, liquid_cash:, income:, spending:,
                     debt_balance:, portfolio_value:, runway_days:, currency:)
        @net_worth = net_worth
        @liquid_cash = liquid_cash
        @income = income
        @spending = spending
        @debt_balance = debt_balance
        @portfolio_value = portfolio_value
        @runway_days = Integer(runway_days)
        @currency = currency
        freeze
      end

      def runway_days
        @runway_days
      end

      # Serialized, UI/cache-ready hash: money as decimal strings plus an integer
      # runway. The currency context lives on the enclosing period/plan, not on
      # each value, matching the spec's "decimal strings plus currency context".
      def to_h
        {
          net_worth: format_money(@net_worth),
          liquid_cash: format_money(@liquid_cash),
          income: format_money(@income),
          spending: format_money(@spending),
          debt_balance: format_money(@debt_balance),
          portfolio_value: format_money(@portfolio_value),
          runway_days: @runway_days
        }
      end

      private
        # Round half-up to MONEY_PRECISION and serialize as a fixed-precision
        # decimal string, never a float.
        def format_money(decimal)
          rounded = decimal.round(MONEY_PRECISION, BigDecimal::ROUND_HALF_UP)
          whole, frac = rounded.to_s("F").split(".")
          frac = (frac || "").ljust(MONEY_PRECISION, "0")[0, MONEY_PRECISION]
          "#{whole}.#{frac}"
        end
    end
  end
end
