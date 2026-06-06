# frozen_string_literal: true

module Forecasts
  # Forecast V2 read model for the assumption rail. Answers exactly ONE UI
  # question: "which assumptions are visible and scannable?"
  #
  # It consumes an already-loaded collection of Forecasts::Assumption records plus
  # the active-in-period assumption ids (from the selected period row). It builds
  # stable, scannable card payloads with NO per-card query, NO engine call, and NO
  # hidden editor-only values (spec "Read Model Contracts", "UI Payload
  # Contracts"). Full editor values live in the EditorPrefillReadModel.
  #
  # Card payloads carry an icon, title, scannable summaries (amount / timing /
  # behavior / source), provenance + review badges, active-in-period state, and
  # the card actions. Summaries are structured (i18n key + raw values, money as
  # decimal strings) so the client formats them — the read model never formats UI
  # strings.
  class AssumptionGroupReadModel
    # Icon (via the `icon` helper, never lucide directly) per assumption kind.
    ICON_FOR_KIND = {
      "salary" => "briefcase",
      "living_expense" => "shopping-cart"
    }.freeze
    DEFAULT_ICON = "circle"

    # The full set of actions a card offers. Editing is always available; move-to
    # -scenario and duplicate round out the scannable card affordances.
    CARD_ACTIONS = %w[edit duplicate move_to_scenario].freeze

    # Display order of group kinds in the rail.
    KIND_ORDER = %w[salary living_expense].freeze

    attr_reader :assumptions, :active_assumption_ids

    # `assumptions` must already be loaded (e.g. `plan.forecast_assumptions
    # .to_a`). `active_assumption_ids` is the set marked active in the selected
    # period (used only to flag cards — no query).
    def initialize(assumptions:, active_assumption_ids: [])
      @assumptions = assumptions
      @active_assumption_ids = Array(active_assumption_ids).map(&:to_s).to_set
    end

    def to_h
      { groups: groups }
    end

    private
      # Cards grouped by kind, group order stable. Built in-memory from the loaded
      # collection — one pass, no per-card query.
      def groups
        by_kind = assumptions.group_by(&:kind)
        ordered_kinds(by_kind).map do |kind|
          {
            kind: kind,
            title_key: "forecasts.assumption_groups.#{kind}",
            cards: by_kind.fetch(kind).map { |assumption| card_for(assumption) }
          }
        end
      end

      def ordered_kinds(by_kind)
        present = by_kind.keys
        (KIND_ORDER & present) + (present - KIND_ORDER)
      end

      def card_for(assumption)
        {
          id: assumption.id,
          kind: assumption.kind,
          icon: ICON_FOR_KIND.fetch(assumption.kind, DEFAULT_ICON),
          title: assumption.name,
          amount_summary: amount_summary(assumption),
          time_summary: time_summary(assumption),
          behavior_summary: behavior_summary(assumption),
          source_summary: source_summary(assumption),
          status_badges: status_badges(assumption),
          active_in_period: active_assumption_ids.include?(assumption.id.to_s),
          actions: CARD_ACTIONS
        }
      end

      # Structured amount summary: decimal-string amount + currency + frequency,
      # plus an i18n key the client renders. Never a pre-formatted money string.
      def amount_summary(assumption)
        {
          key: "forecasts.cards.amount_summary",
          amount: assumption.amount&.to_s,
          currency: assumption.currency,
          frequency: params(assumption)["frequency"]
        }
      end

      # Structured timing summary: start/end anchors as raw dates + a key.
      def time_summary(assumption)
        {
          key: "forecasts.cards.time_summary",
          starts_on: assumption.starts_on&.iso8601,
          ends_on: assumption.ends_on&.iso8601
        }
      end

      # Behavior summary: growth/basis params that shape the projection over time.
      def behavior_summary(assumption)
        p = params(assumption)
        {
          key: "forecasts.cards.behavior_summary",
          basis: p["basis"],
          growth_rate: p["growth_rate"],
          inflation_rate: p["inflation_rate"]
        }
      end

      # Source/provenance summary: where the assumption came from.
      def source_summary(assumption)
        {
          key: "forecasts.cards.source_summary",
          origin: assumption.origin,
          source_record_type: assumption.source_record_type
        }
      end

      # Provenance + review badges (privacy-safe, no record details). A
      # source-derived assumption awaiting review surfaces a "review_suggested"
      # badge; low confidence surfaces a confidence badge.
      def status_badges(assumption)
        badges = []
        badges << "review_suggested" if assumption.review_state == "needs_review"
        badges << "derived" if assumption.origin == "source_derived"
        badges << "low_confidence" if assumption.confidence == "low"
        badges << "disabled" if assumption.status == "disabled"
        badges
      end

      def params(assumption)
        assumption.params || {}
      end
  end
end
