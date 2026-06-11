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

        # Shares expanded occurrence walks across the expanders of one engine
        # run. A 30-year x 25-assumption plan expands 25 IDENTICAL monthly date
        # sequences (same window, same frequency); walking Date#>> and
        # serializing ISO strings 25 times over was a measurable slice of the
        # engine perf budget. The engine threads one instance per run through
        # context[:occurrence_cache] (a plain object, so deep_symbolize passes
        # it through by identity). Purely a memo of deterministic derivations —
        # sharing cannot change output.
        class OccurrenceWalkCache
          def initialize
            @walks = {}
          end

          def fetch(frequency, start_on, end_on)
            @walks[[ frequency, start_on, end_on ]] ||= yield
          end
        end

        # Money is computed with this many fractional digits then serialized to a
        # currency-agnostic decimal string. The UI rounds for display.
        MONEY_PRECISION = 2

        attr_reader :params, :context

        def initialize(params:, context:)
          @params = symbolize(params)
          @context = symbolize(context)
        end

        # Returns an ordered array of Forecasts::Projection::FlowLedger::Flow —
        # the validating boundary object. Both this and #expand_rows are driven
        # by the subclass's #each_flow (one shared occurrence walk), so the two
        # paths cannot drift apart.
        def expand
          flows = []
          each_flow do |category, direction, source_kind, date, amount, currency, sequence, metadata|
            flows << build_flow(
              category: category, direction: direction, source_kind: source_kind,
              date: date, amount: amount, currency: currency,
              sequence: sequence, metadata: metadata
            )
          end
          flows
        end

        # Returns an ordered array of Forecasts::Projection::FlowRow — the
        # engine's compact hot-path representation (see FlowRow for why). Keys,
        # ordering, and money strings are identical to #expand's Flow VOs.
        def expand_rows
          rows = []
          each_flow do |category, direction, source_kind, date, amount, currency, sequence, metadata, date_iso, period_key|
            rows << build_flow_row(
              category, direction, source_kind, date, amount, currency, sequence, metadata,
              date_iso, period_key
            )
          end
          rows
        end

        private
          # Subclasses yield one tuple per occurrence, in date order:
          #   (category, direction, source_kind, date, amount_string, currency,
          #    sequence, metadata[, date_iso, period_key])
          # Positional (not a hash) on purpose — this runs once per flow in the
          # engine's hot path. The two optional trailing strings are the
          # occurrence's pre-derived ISO date / YYYY-MM period key (as yielded
          # by each_occurrence); when omitted build_flow_row derives them.
          def each_flow
            raise NotImplementedError, "#{self.class} must implement #each_flow"
          end

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
          # Also yields the occurrence's derived ISO date string and YYYY-MM
          # period key (Flow's own formulas) so hot-path callers can thread the
          # shared, pre-computed strings into build_flow_row; blocks that only
          # take |date, index| simply ignore them.
          def each_occurrence(frequency, start_on, end_on)
            return enum_for(:each_occurrence, frequency, start_on, end_on) unless block_given?

            occurrence_walk(frequency, start_on, end_on).each_with_index do |(date, date_iso, period_key), index|
              yield date, index, date_iso, period_key
            end
          end

          # The [date, date_iso, period_key] tuples for one frequency window,
          # shared across the run's expanders via the engine-provided
          # OccurrenceWalkCache when present.
          def occurrence_walk(frequency, start_on, end_on)
            cache = context[:occurrence_cache]
            return expand_occurrence_walk(frequency, start_on, end_on) unless cache

            cache.fetch(frequency.to_s, start_on, end_on) do
              expand_occurrence_walk(frequency, start_on, end_on)
            end
          end

          def expand_occurrence_walk(frequency, start_on, end_on)
            freq = frequency.to_s
            occurrences = []
            index = 0
            date = start_on

            loop do
              break if date > end_on

              date_iso = date.iso8601.freeze
              occurrences << [ date, date_iso, date_iso[0, 7].freeze ].freeze
              break if freq == "one_time"

              index += 1
              date = advance(start_on, freq, index)
            end

            occurrences.freeze
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

          # Whole years elapsed since the start anchor's anniversary, i.e.
          # `occurrence year - start year`, minus one when the occurrence falls
          # before that year's anniversary (month, day) — with a Feb 29 anchor
          # falling back to Feb 28 in non-leap years, exactly as constructing
          # the anniversary via Date.new with an ArgumentError rescue did.
          # Plain integer comparisons: building an anniversary Date per
          # occurrence (~9k on a 30-year plan) was a measurable slice of the
          # engine perf budget.
          def elapsed_years(start_on, occurrence_on)
            years = occurrence_on.year - start_on.year
            return 0 if years <= 0

            month = start_on.month
            day = start_on.day
            # Feb 29 anchors in non-leap years fall back to Feb 28.
            day = 28 if day == 29 && month == 2 && !occurrence_on.leap?

            occurrence_month = occurrence_on.month
            if occurrence_month < month || (occurrence_month == month && occurrence_on.day < day)
              years -= 1
            end
            years
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
          def flow_key(kind:, date:, sequence:, date_iso: nil)
            @flow_key_prefix ||= "#{context[:plan_version]}.#{context[:scenario_layer_id] || 'baseline'}.#{context[:assumption_id]}"
            "#{kind}-#{@flow_key_prefix}.#{date_iso || date.iso8601}.#{sequence}"
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

          # Pre-padded sequence strings for ledger sort keys. Sequences are
          # dense small integers (a 30-year monthly assumption peaks at 361,
          # weekly at ~1.6k), so the table covers the realistic range and the
          # rjust fallback handles anything beyond it. Identical output to
          # `sequence.to_s.rjust(8, '0')` — Flow's own formula.
          PADDED_SEQUENCES = Array.new(2048) { |i| format("%08d", i).freeze }.freeze
          private_constant :PADDED_SEQUENCES

          # Plain sequence strings for flow keys (same realistic range +
          # fallback as PADDED_SEQUENCES). Interpolating the Integer directly
          # allocated a fresh conversion string per flow.
          SEQUENCE_STRINGS = Array.new(2048) { |i| i.to_s.freeze }.freeze
          private_constant :SEQUENCE_STRINGS

          # Hot-path twin of build_flow: same derived values (date_iso,
          # period_key, flow key, ledger sort key — Flow's own formulas, with
          # flow_key's interpolation inlined per-kind), no per-row
          # validation/freeze (see FlowRow).
          def build_flow_row(category, direction, source_kind, date, amount, currency, sequence, metadata, date_iso = nil, period_key = nil)
            date_iso ||= date.iso8601
            sequence_string = SEQUENCE_STRINGS[sequence] || sequence.to_s
            key = "#{row_key_prefix(source_kind)}#{date_iso}.#{sequence_string}"
            rank = Forecasts::Projection::FlowLedger::Flow::SORT_RANK
              .fetch(category, Forecasts::Projection::FlowLedger::Flow::DEFAULT_SORT_RANK)
            padded = PADDED_SEQUENCES[sequence] || sequence.to_s.rjust(8, "0")

            Forecasts::Projection::FlowRow.new(
              date_iso,
              period_key || date_iso[0, 7],
              amount,
              currency,
              category,
              direction,
              source_kind,
              @assumption_id ||= context[:assumption_id],
              @scenario_layer_id ||= context[:scenario_layer_id],
              key,
              sequence,
              metadata,
              "#{date_iso}|#{rank}|#{padded}|#{key}"
            )
          end

          # The constant flow-key head for one source kind — everything before
          # the occurrence date. Matches #flow_key's output byte-for-byte.
          def row_key_prefix(kind)
            @row_key_prefixes ||= {}
            @row_key_prefixes[kind] ||=
              "#{kind}-#{context[:plan_version]}.#{context[:scenario_layer_id] || 'baseline'}.#{context[:assumption_id]}."
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
