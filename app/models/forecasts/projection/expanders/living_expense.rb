# frozen_string_literal: true

require "bigdecimal"

module Forecasts
  module Projection
    module Expanders
      # Expands a typed `living_expense` assumption into dated spending flows with
      # inflation, a category rollup, and trace links. Pure: receives typed
      # params, normalized source-snapshot/scenario context, and resolved
      # milestone dates; reads no ActiveRecord and no clock.
      #
      # Required params (see "Assumption Params Contracts"): `amount`,
      # `currency`, `frequency`, `category_ids`, `inflation_policy`,
      # `actualization_policy`, `start_anchor`, `end_anchor`.
      #
      # Inflation compounds annually against the window start. The category
      # rollup is carried in trace metadata so the cash-flow lens can group
      # spending by category without re-querying source records.
      class LivingExpense < Base
        SOURCE_KIND = "living_expense"

        def expand
          window = occurrence_window
          return [] if window.nil?

          start_on, end_on = window
          base_amount = to_decimal(params[:amount])
          currency = params[:currency] || context[:reporting_currency]

          each_occurrence(params[:frequency], start_on, end_on).map do |date, index|
            amount = base_amount * inflation_factor(start_on, date)

            build_flow(
              category: "spending",
              direction: "outflow",
              source_kind: SOURCE_KIND,
              date: date,
              amount: format_money(amount),
              currency: currency,
              sequence: index,
              metadata: {
                category_ids: category_ids,
                inflation_policy_type: inflation_policy[:type].to_s,
                actualization_policy_type: actualization_policy[:type].to_s,
                frequency: params[:frequency].to_s
              }
            )
          end
        end

        private
          def category_ids
            Array(params[:category_ids]).map(&:to_s)
          end

          def inflation_policy
            @inflation_policy ||= policy_hash(params[:inflation_policy])
          end

          def actualization_policy
            @actualization_policy ||= policy_hash(params[:actualization_policy])
          end

          # Policies are read as typed hashes (`policy[:type]`). The packet
          # builder normalizes the persisted flat-string form shape into hashes,
          # but coerce defensively here so a non-hash value can never raise a
          # TypeError that escapes the engine's expander rescue (which only
          # catches InvalidExpansionError).
          def policy_hash(value)
            symbolized = symbolize(value || {})
            symbolized.is_a?(Hash) ? symbolized : {}
          end

          def inflation_factor(start_on, occurrence_on)
            case inflation_policy[:type].to_s
            when "annual_percentage"
              annual_compounding_factor(inflation_policy[:rate], start_on, occurrence_on)
            else
              BigDecimal("1")
            end
          end
      end
    end
  end
end
