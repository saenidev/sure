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
              years = elapsed_years(start_on, date)
              gross, net = amounts_for(base_amount, start_on, date, years)
              metadata = metadata_for(gross, net, years)

              yield "income", "inflow", SOURCE_KIND, date,
                metadata[:net_amount], currency, index, metadata, date_iso, period_key
            end
          end

          def gross_or_net
            (params[:gross_or_net] || "net").to_s
          end

          # Metadata varies only with the growth year (a single hash when
          # flat), so a 361-occurrence expansion shares a handful of
          # pre-symbolized frozen hashes instead of building and deep-freezing
          # one per flow. Frozen here so Flow#initialize takes its
          # canonical-metadata fast path.
          def metadata_for(gross, net, years)
            @metadata_cache ||= {}
            @metadata_cache[years] ||= {
              person_key: params[:person_key],
              gross_or_net: gross_or_net,
              gross_amount: format_money(gross),
              net_amount: format_money(net),
              frequency: params[:frequency].to_s
            }.freeze
          end

          # Returns [gross, net] decimals for the occurrence. Growth compounds
          # annually against the window start. When modeled as gross, net is
          # derived via `net_ratio` (defaulting to 1.0 when absent so we never
          # silently fabricate a take-home cut). Memoized per growth year — the
          # decimals are identical for every occurrence inside one year.
          def amounts_for(base_amount, start_on, occurrence_on, years)
            @amounts_cache ||= {}
            @amounts_cache[years] ||= begin
              grown = base_amount * growth_factor(start_on, occurrence_on)

              if gross_or_net == "gross"
                [ grown, grown * net_ratio ]
              else
                [ grown, grown ]
              end
            end
          end

          def net_ratio
            ratio = params[:net_ratio]
            return BigDecimal("1") if ratio.nil? || ratio == ""

            to_decimal(ratio)
          end

          def growth_factor(start_on, occurrence_on)
            case growth_policy[:type].to_s
            when "annual_percentage"
              annual_compounding_factor(growth_policy[:rate], start_on, occurrence_on)
            else
              BigDecimal("1")
            end
          end

          # Params are deep-symbolized once in Base#initialize; coerce
          # defensively (mirroring LivingExpense#policy_hash) so a non-hash
          # value can never raise a TypeError that escapes the engine's
          # expander rescue.
          def growth_policy
            @growth_policy ||= begin
              policy = params[:growth_policy] || {}
              policy.is_a?(Hash) ? policy : {}
            end
          end
      end
    end
  end
end
