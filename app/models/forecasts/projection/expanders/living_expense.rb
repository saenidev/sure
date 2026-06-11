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

        private
          # One shared occurrence walk driving both Base#expand (Flow VOs) and
          # Base#expand_rows (engine FlowRows) — see Base#each_flow's contract.
          def each_flow
            window = occurrence_window
            return if window.nil?

            start_on, end_on = window
            base_amount = to_decimal(params[:amount])
            currency = params[:currency] || context[:reporting_currency]

            each_occurrence(params[:frequency], start_on, end_on) do |date, index, date_iso, period_key|
              yield "spending", "outflow", SOURCE_KIND, date,
                amount_string(base_amount, start_on, date), currency, index, flow_metadata,
                date_iso, period_key
            end
          end

          def category_ids
            Array(params[:category_ids]).map(&:to_s)
          end

          # Constant across the whole expansion (category rollup and policy
          # types don't vary per occurrence), so every flow shares one
          # pre-symbolized frozen hash. Frozen here so Flow#initialize takes
          # its canonical-metadata fast path.
          def flow_metadata
            @flow_metadata ||= {
              category_ids: category_ids.freeze,
              inflation_policy_type: inflation_policy[:type].to_s,
              actualization_policy_type: actualization_policy[:type].to_s,
              frequency: params[:frequency].to_s
            }.freeze
          end

          # Memoized per inflation year — the serialized amount is identical
          # for every occurrence inside one year, so a 361-occurrence
          # expansion computes and formats ~31 decimals, not 361.
          def amount_string(base_amount, start_on, occurrence_on)
            years = elapsed_years(start_on, occurrence_on)
            @amount_strings ||= {}
            @amount_strings[years] ||=
              format_money(base_amount * inflation_factor(start_on, occurrence_on))
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
