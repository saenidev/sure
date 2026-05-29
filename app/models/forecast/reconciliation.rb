module Forecast
  # Read-only query object for the Reconciliation tab. It pairs every family
  # forecast event with a DERIVED lifecycle state computed from the event's
  # occurrence date (vs Date.current) and its accepted links.
  #
  # Per the Self-Review note, occurrence lifecycle lives on the LINK, not on the
  # event: we never mutate ForecastEvent#status here. The event's own `status`
  # (planned/accepted/ignored/disabled) is the user's authoring intent; the
  # reconciliation lifecycle (planned/due_soon/matched/missed) is computed.
  #
  # Lifecycle rules (for the event's occurrence date):
  #   matched   -> the occurrence has an accepted link (regardless of date)
  #   due_soon  -> no accepted link, occurrence is today or within the window
  #   planned   -> no accepted link, occurrence is in the future beyond window
  #   missed    -> no accepted link, occurrence is in the past beyond window
  #
  # Everything is scoped through the family association.
  class Reconciliation
    # How many days ahead of today an unmatched occurrence is "due soon".
    DUE_SOON_WINDOW = 7

    LIFECYCLE_STATES = %w[matched due_soon planned missed].freeze

    Row = Data.define(:event, :occurrence_on, :lifecycle_state, :accepted_link) do
      def matched?
        lifecycle_state == "matched"
      end
    end

    def initialize(family:, today: Date.current, due_soon_window: DUE_SOON_WINDOW)
      @family = family
      @today = today
      @due_soon_window = due_soon_window.to_i
    end

    # All events with their derived lifecycle row, ordered by occurrence date.
    # Eager-loads the associations each row reads (account/category/scenario) and
    # the accepted links in one query so the view never N+1s.
    def rows
      @rows ||= events.map { |event| build_row(event) }
    end

    # Lifecycle counts for the tab summary header. Computed from `rows` so it
    # shares the single load.
    def counts
      @counts ||= rows.each_with_object(Hash.new(0)) do |row, memo|
        memo[row.lifecycle_state] += 1
      end
    end

    def empty?
      rows.empty?
    end

    # Scored match candidates for ONE unmatched row, built from data loaded in a
    # SINGLE batched pass across every unmatched row (see #candidate_entry_pool /
    # #claimed_entry_ids_for). This replaces the old per-row MatchCandidateBuilder
    # that issued ~3-4 queries for every unmatched event on every forecast page
    # load; here the shared entry pool + accepted-claim set are loaded once and
    # the per-row builder does its scoring in Ruby with no further queries.
    def candidates_for(row)
      return [] if row.matched?

      Forecast::MatchCandidateBuilder.new(
        family: family,
        event: row.event,
        occurrence_on: row.occurrence_on,
        candidate_entries: candidate_entry_pool,
        claimed_entry_ids: claimed_entry_ids_for(row)
      ).call
    end

    private
      attr_reader :family, :today, :due_soon_window

      def events
        family.forecast_events
          .includes(:account, :category, :forecast_scenario)
          .order(starts_on: :asc, created_at: :asc)
          .to_a
      end

      # Map of forecast_event_id -> accepted ForecastEventLink. Loaded once for
      # all events so deriving each row's state adds no per-event query. When an
      # event has several accepted occurrences we keep the earliest (the headline
      # occurrence the tab renders).
      def accepted_links_by_event
        @accepted_links_by_event ||= begin
          links = family.forecast_event_links
            .where(status: "accepted")
            .where.not(forecast_event_id: nil)
            .order(occurrence_on: :asc)
            .to_a

          links.each_with_object({}) do |link, memo|
            memo[link.forecast_event_id] ||= link
          end
        end
      end

      def build_row(event)
        occurrence_on = event.starts_on
        accepted = accepted_links_by_event[event.id]

        Row.new(
          event: event,
          occurrence_on: occurrence_on,
          lifecycle_state: lifecycle_state_for(occurrence_on, accepted),
          accepted_link: accepted
        )
      end

      def lifecycle_state_for(occurrence_on, accepted_link)
        return "matched" if accepted_link.present?
        return "planned" if occurrence_on.blank?

        if occurrence_on < today
          "missed"
        elsif occurrence_on <= today + due_soon_window
          "due_soon"
        else
          "planned"
        end
      end

      # --- batched candidate matching (one pass for every unmatched row) --------

      def unmatched_rows
        @unmatched_rows ||= rows.reject(&:matched?)
      end

      # The single transaction-entry pool the per-row builders filter in Ruby.
      # Loads, in ONE query, every family Transaction entry inside the UNION of
      # all unmatched rows' date windows (with the records each candidate reads
      # eager-loaded). Returns [] when there is nothing to match so no query runs.
      def candidate_entry_pool
        return @candidate_entry_pool if defined?(@candidate_entry_pool)

        windows = unmatched_rows.filter_map { |row| candidate_window(row.occurrence_on) }
        if windows.empty?
          return @candidate_entry_pool = []
        end

        earliest = windows.map(&:begin).min
        latest = windows.map(&:end).max

        @candidate_entry_pool = family.entries
          .where(entryable_type: "Transaction")
          .where(excluded: false)
          .where(date: earliest..latest)
          .includes(:account, entryable: :category)
          .to_a
      end

      # Entry ids claimed by an ACCEPTED link anywhere in the family. Loaded once
      # and shared across rows (the same exclusion the per-event builder applied).
      def accepted_claimed_entry_ids
        @accepted_claimed_entry_ids ||= family.forecast_event_links
          .where(status: "accepted")
          .where.not(entry_id: nil)
          .pluck(:entry_id)
      end

      # Map of [event_id, occurrence_on] -> entry ids already linked to that exact
      # occurrence (any status), loaded once so re-proposing a known link is
      # avoided without a per-row query.
      def occurrence_claimed_entry_ids
        @occurrence_claimed_entry_ids ||= begin
          family.forecast_event_links
            .where.not(entry_id: nil)
            .where.not(forecast_event_id: nil)
            .pluck(:forecast_event_id, :occurrence_on, :entry_id)
            .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(event_id, occurrence_on, entry_id), memo|
              memo[[ event_id, occurrence_on ]] << entry_id
            end
        end
      end

      # The full claimed-id exclusion for one row: the shared accepted set plus
      # any entry already linked to this event at this occurrence.
      def claimed_entry_ids_for(row)
        (accepted_claimed_entry_ids + occurrence_claimed_entry_ids[[ row.event.id, row.occurrence_on ]]).uniq
      end

      def candidate_window(occurrence_on)
        return nil if occurrence_on.blank?

        (occurrence_on - MatchCandidateBuilder::DEFAULT_DATE_WINDOW)..(occurrence_on + MatchCandidateBuilder::DEFAULT_DATE_WINDOW)
      end
  end
end
