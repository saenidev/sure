module Forecast
  # Query/scoring PORO that proposes candidate actual entries for an unmatched
  # forecast event occurrence. This is the deliberately-simple first cut of
  # automated matching (the spec's "automated matching can start simple"):
  # it compares the family's transaction entries inside a date window against
  # the event's occurrence, scoring on date proximity, amount tolerance,
  # account, category, and cash-flow direction.
  #
  # Everything is scoped through the family association, so it can never surface
  # another family's entries. It only ever READS — it does not create links or
  # mutate the event.
  class MatchCandidateBuilder
    # How many days on either side of the occurrence we look for actuals.
    DEFAULT_DATE_WINDOW = 7
    # Fraction of the expected amount the actual may differ by and still match
    # (0.10 == within 10%). A small absolute floor avoids rejecting tiny amounts
    # where 10% is pennies.
    DEFAULT_AMOUNT_TOLERANCE = 0.10
    MIN_ABSOLUTE_TOLERANCE = 1.to_d
    # Most confident candidates first; cap so a noisy window can't render a wall.
    DEFAULT_LIMIT = 5

    Candidate = Data.define(:entry, :confidence, :reasons) do
      # Coarse bucket for the UI's confidence indicator so the view does not
      # re-derive thresholds.
      def confidence_level
        if confidence >= 0.75 then "high"
        elsif confidence >= 0.5 then "medium"
        else "low"
        end
      end

      def to_match_metadata
        {
          "confidence" => confidence.to_s,
          "confidence_level" => confidence_level,
          "reasons" => reasons,
          "matched_at" => Time.current.iso8601
        }
      end
    end

    def initialize(family:, event:, occurrence_on: nil, date_window: DEFAULT_DATE_WINDOW,
                   amount_tolerance: DEFAULT_AMOUNT_TOLERANCE, limit: DEFAULT_LIMIT)
      @family = family
      @event = event
      @occurrence_on = occurrence_on || event&.starts_on
      @date_window = date_window.to_i
      @amount_tolerance = amount_tolerance.to_d
      @limit = limit
    end

    # Returns scored Candidate structs, best first, excluding any entry that is
    # already accepted-linked to ANY event (so an actual is never double-claimed)
    # or already linked to THIS event occurrence.
    def call
      return [] if event.blank? || occurrence_on.blank?
      return [] unless event.effect_type.in?(ForecastEvent::DIRECTIONAL_AMOUNT_EFFECT_TYPES)

      entries = candidate_entries
      return [] if entries.empty?

      entries
        .map { |entry| score(entry) }
        .select { |candidate| candidate.confidence.positive? }
        .sort_by { |candidate| -candidate.confidence }
        .first(@limit)
    end

    private
      attr_reader :family, :event, :occurrence_on, :amount_tolerance

      # Family transaction entries inside the date window and matching the
      # event's cash-flow direction, with the records each candidate row reads
      # eager-loaded so scoring/rendering never N+1s. Excludes entries already
      # claimed by an accepted link or already linked to this occurrence.
      def candidate_entries
        scope = family.entries
          .where(entryable_type: "Transaction")
          .where(date: window_range)
          .where(direction_condition)
          .where(excluded: false)
          .where.not(id: claimed_entry_ids)
          .includes(:account, entryable: :category)

        scope.to_a
      end

      def window_range
        (occurrence_on - @date_window)..(occurrence_on + @date_window)
      end

      # Income events expect an inflow (negative signed amount in Sure's ledger),
      # every other directional effect expects an outflow (positive amount).
      def direction_condition
        if expects_inflow?
          [ "entries.amount < 0" ]
        else
          [ "entries.amount >= 0" ]
        end
      end

      def expects_inflow?
        event.effect_type == "income"
      end

      # Entry ids that are off the table: any entry with an accepted link
      # (claimed elsewhere), plus any entry already linked to this event at this
      # occurrence (candidate/accepted/etc.) so we don't re-propose a known link.
      def claimed_entry_ids
        accepted = family.forecast_event_links
          .where(status: "accepted")
          .where.not(entry_id: nil)
          .pluck(:entry_id)

        this_occurrence = family.forecast_event_links
          .where(forecast_event_id: event.id, occurrence_on: occurrence_on)
          .where.not(entry_id: nil)
          .pluck(:entry_id)

        (accepted + this_occurrence).uniq
      end

      def score(entry)
        reasons = []
        score = 0.0

        # Date proximity: full weight on the occurrence day, decaying to zero at
        # the window edge.
        distance = (entry.date - occurrence_on).to_i.abs
        date_score = [ 1.0 - (distance.to_f / [ @date_window, 1 ].max), 0.0 ].max
        score += date_score * 0.4
        reasons << "date_within_window" if date_score.positive?

        # Amount proximity within tolerance.
        if amount_within_tolerance?(entry)
          score += 0.35
          reasons << "amount_within_tolerance"
        end

        # Same account as the event's source account.
        if event.account_id.present? && entry.account_id == event.account_id
          score += 0.15
          reasons << "account_match"
        end

        # Same category as the event.
        if event.category_id.present? && entry_category_id(entry) == event.category_id
          score += 0.10
          reasons << "category_match"
        end

        Candidate.new(entry: entry, confidence: score.round(4), reasons: reasons)
      end

      def amount_within_tolerance?(entry)
        expected = event.amount&.to_d&.abs
        return false if expected.blank? || expected.zero?

        actual = entry.amount.to_d.abs
        tolerance = [ expected * amount_tolerance, MIN_ABSOLUTE_TOLERANCE ].max
        (actual - expected).abs <= tolerance
      end

      def entry_category_id(entry)
        return nil unless entry.entryable_type == "Transaction"

        entry.entryable.category_id
      end
  end
end
