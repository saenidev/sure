# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module Forecasts
  module Projection
    module Expanders
      # Shared, pure machinery for typed assumption expanders. Expanders receive
      # typed params, the normalized source-snapshot/scenario context, and
      # resolved milestone dates. They never read ActiveRecord and never read
      # `Date.current` — the run/as-of date is threaded through the context.
      #
      # Responsibilities provided here:
      # - normalize start/end anchors (fixed dates or already-resolved milestone
      #   references) to deterministic dates, clamped to the plan horizon,
      # - expand a frequency over a [start, end] window into occurrence dates,
      # - decimal money math and serialization to decimal strings,
      # - stable flow-key derivation for trace links.
      #
      # See spec "Assumption Expansion", "Assumption Type Registry Contract"
      # (expander rules), and "Assumption Params Contracts" (anchor
      # normalization).
      class Base
        InvalidExpansionError = Class.new(ArgumentError)

        # Money is computed with this many fractional digits then serialized to a
        # currency-agnostic decimal string. The UI rounds for display.
        MONEY_PRECISION = 2

        attr_reader :params, :context

        def initialize(params:, context:)
          @params = symbolize(params)
          @context = symbolize(context)
        end

        # Returns an ordered array of Forecasts::Projection::FlowLedger::Flow.
        def expand
          raise NotImplementedError, "#{self.class} must implement #expand"
        end

        private
          # --- Anchor normalization ------------------------------------------

          # Resolve the inclusive [start, end] occurrence window for this
          # assumption, clamped into the plan horizon. Returns nil when the
          # window is empty (end before start) so the expander emits no flows.
          def occurrence_window
            start_on = resolve_anchor(params[:start_anchor]) || horizon_start
            end_on = resolve_anchor(params[:end_anchor]) || horizon_end

            start_on = [ start_on, horizon_start ].max
            end_on = [ end_on, horizon_end ].min

            return nil if end_on < start_on

            [ start_on, end_on ]
          end

          # Anchors are either fixed dates or milestone references. Milestone
          # references must already be resolved to deterministic dates by the
          # caller and passed in via context[:milestone_dates]; the expander only
          # looks them up. Anything unresolvable raises a typed error rather than
          # silently producing wrong flows.
          def resolve_anchor(anchor)
            return nil if anchor.nil?

            anchor = symbolize(anchor)
            type = anchor[:type].to_s

            case type
            when "date"
              parse_date(anchor[:on] || anchor[:date])
            when "milestone"
              key = (anchor[:milestone_key] || anchor[:key]).to_s
              resolved = milestone_dates[key] || milestone_dates[key.to_sym]
              if resolved.nil?
                raise InvalidExpansionError,
                  "Unresolved milestone reference #{key.inspect}; milestone dates must be resolved before expansion"
              end
              parse_date(resolved)
            else
              raise InvalidExpansionError, "Unknown anchor type #{type.inspect}"
            end
          end

          def milestone_dates
            context[:milestone_dates] || {}
          end

          def horizon
            context[:horizon] || {}
          end

          def horizon_start
            @horizon_start ||= parse_date(horizon[:starts_on])
          end

          def horizon_end
            @horizon_end ||= parse_date(horizon[:ends_on])
          end

          # --- Frequency expansion -------------------------------------------

          # Yields each occurrence date in [start, end] for the given frequency,
          # together with a zero-based index. Deterministic for the same inputs.
          def each_occurrence(frequency, start_on, end_on)
            return enum_for(:each_occurrence, frequency, start_on, end_on) unless block_given?

            freq = frequency.to_s
            index = 0
            date = start_on

            loop do
              break if date > end_on

              yield date, index
              break if freq == "one_time"

              index += 1
              date = advance(start_on, freq, index)
            end
          end

          # Advance `index` periods from the anchor. Month/year-based frequencies
          # advance from the anchor (not the previous date) so day-of-month is
          # preserved and there is no drift.
          def advance(anchor, frequency, index)
            case frequency
            when "weekly" then anchor + (7 * index)
            when "biweekly" then anchor + (14 * index)
            when "monthly" then anchor >> index
            when "quarterly" then anchor >> (3 * index)
            when "semiannual" then anchor >> (6 * index)
            when "annual", "yearly" then anchor >> (12 * index)
            else
              raise InvalidExpansionError, "Unsupported frequency #{frequency.inspect}"
            end
          end

          # --- Growth / inflation --------------------------------------------

          # Compounding annual multiplier for the number of completed years
          # between the start anchor and the occurrence date. Anniversaries are
          # measured against the window start so a mid-year occurrence still
          # belongs to its growth year. Memoized per (rate, years): a 30-year
          # monthly assumption has 361 occurrences but only ~31 distinct factor
          # years, and BigDecimal exponentiation per occurrence dominated the
          # engine perf budget.
          def annual_compounding_factor(rate, start_on, occurrence_on)
            years = elapsed_years(start_on, occurrence_on)
            @compounding_factors ||= {}
            @compounding_factors[[ rate, years ]] ||=
              (BigDecimal("1") + to_decimal(rate)) ** years
          end

          # Whole years elapsed since the start anchor's anniversary.
          def elapsed_years(start_on, occurrence_on)
            years = occurrence_on.year - start_on.year
            anniversary = safe_change_year(start_on, occurrence_on.year)
            years -= 1 if occurrence_on < anniversary
            [ years, 0 ].max
          end

          def safe_change_year(date, year)
            Date.new(year, date.month, date.day)
          rescue ArgumentError
            # Feb 29 anchors in non-leap years fall back to Feb 28.
            Date.new(year, date.month, date.day - 1)
          end

          # --- Money ----------------------------------------------------------

          def to_decimal(value)
            return BigDecimal("0") if value.nil? || value == ""

            BigDecimal(value.to_s)
          end

          # Round half-up to MONEY_PRECISION and serialize as a fixed-precision
          # decimal string (never a float). Memoized per distinct value: flat
          # assumptions repeat the same amount every occurrence and grown ones
          # have one value per year, so a 361-occurrence expansion serializes a
          # handful of distinct decimals, not 361.
          def format_money(decimal)
            @money_strings ||= {}
            @money_strings[decimal] ||=
              decimal.round(MONEY_PRECISION).to_s("F").then { |s| pad_decimal(s) }
          end

          def pad_decimal(string)
            whole, frac = string.split(".")
            frac = (frac || "").ljust(MONEY_PRECISION, "0")[0, MONEY_PRECISION]
            "#{whole}.#{frac}"
          end

          # --- Flow building --------------------------------------------------

          # Stable flow key for trace links: derived from plan version,
          # assumption id, scenario layer, occurrence date, and an intra-day
          # sequence so the same plan+assumption always yields the same key.
          # A plain delimited composite (not a digest): the trailing parts have
          # rigid formats (ISO date, integer), so distinct inputs always yield
          # distinct keys, and skipping SHA256 here matters — two digests per
          # flow across a 30-year x 25-assumption expansion (~18k digests)
          # consumed a meaningful slice of the <100ms engine budget on their own.
          def flow_key(kind:, date:, sequence:)
            @flow_key_prefix ||= "#{context[:plan_version]}.#{context[:scenario_layer_id] || 'baseline'}.#{context[:assumption_id]}"
            "#{kind}-#{@flow_key_prefix}.#{date.iso8601}.#{sequence}"
          end

          def build_flow(category:, direction:, source_kind:, date:, amount:, currency:, sequence:, metadata:)
            Forecasts::Projection::FlowLedger::Flow.new(
              date: date,
              amount: amount,
              currency: currency,
              category: category,
              direction: direction,
              source_kind: source_kind,
              assumption_id: context[:assumption_id],
              scenario_layer_id: context[:scenario_layer_id],
              flow_key: flow_key(kind: source_kind, date: date, sequence: sequence),
              sequence: sequence,
              metadata: metadata
            )
          end

          # --- Helpers --------------------------------------------------------

          def parse_date(value)
            return nil if value.nil? || value == ""
            return value if value.is_a?(Date)

            Date.parse(value.to_s)
          end

          def symbolize(value)
            Forecasts::Projection.deep_symbolize(value)
          end
      end
    end
  end
end
