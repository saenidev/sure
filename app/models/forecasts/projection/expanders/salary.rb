# frozen_string_literal: true

require "bigdecimal"

module Forecasts
  module Projection
    module Expanders
      # Expands a typed `salary` assumption into dated income flows with explicit
      # gross/net interpretation and trace links. Pure: receives typed params,
      # normalized source-snapshot/scenario context, and resolved milestone
      # dates; reads no ActiveRecord and no clock.
      #
      # Required params (see "Assumption Params Contracts"): `person_key`,
      # `amount`, `gross_or_net`, `currency`, `frequency`, `growth_policy`,
      # `start_anchor`, `end_anchor`. Optional `net_ratio` lets a gross salary
      # derive take-home pay for cash impact.
      #
      # Cash impact uses the net (take-home) amount; the gross amount is carried
      # in trace metadata so the UI can label gross vs net (journey "Edit Salary
      # Like A Planning Assumption").
      class Salary < Base
        SOURCE_KIND = "salary"

        def expand
          window = occurrence_window
          return [] if window.nil?

          start_on, end_on = window
          base_amount = to_decimal(params[:amount])
          currency = params[:currency] || context[:reporting_currency]

          each_occurrence(params[:frequency], start_on, end_on).map do |date, index|
            gross, net = amounts_for(base_amount, start_on, date)

            build_flow(
              category: "income",
              direction: "inflow",
              source_kind: SOURCE_KIND,
              date: date,
              amount: format_money(net),
              currency: currency,
              sequence: index,
              metadata: {
                person_key: params[:person_key],
                gross_or_net: gross_or_net,
                gross_amount: format_money(gross),
                net_amount: format_money(net),
                frequency: params[:frequency].to_s
              }
            )
          end
        end

        private
          def gross_or_net
            (params[:gross_or_net] || "net").to_s
          end

          # Returns [gross, net] decimals for the occurrence. Growth compounds
          # annually against the window start. When modeled as gross, net is
          # derived via `net_ratio` (defaulting to 1.0 when absent so we never
          # silently fabricate a take-home cut).
          def amounts_for(base_amount, start_on, occurrence_on)
            grown = base_amount * growth_factor(start_on, occurrence_on)

            if gross_or_net == "gross"
              [ grown, grown * net_ratio ]
            else
              [ grown, grown ]
            end
          end

          def net_ratio
            ratio = params[:net_ratio]
            return BigDecimal("1") if ratio.nil? || ratio == ""

            to_decimal(ratio)
          end

          def growth_factor(start_on, occurrence_on)
            policy = symbolize(params[:growth_policy] || {})

            case policy[:type].to_s
            when "annual_percentage"
              annual_compounding_factor(policy[:rate], start_on, occurrence_on)
            else
              BigDecimal("1")
            end
          end
      end
    end
  end
end
