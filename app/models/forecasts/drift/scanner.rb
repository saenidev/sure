# frozen_string_literal: true

module Forecasts
  module Drift
    # Re-derives each LINKED source-derived assumption via
    # Forecasts::Derivation and caches the verdict on assumption.drift:
    #
    #   {
    #     "status"          => "drifted" | "source_gone",
    #     "proposed_amount" => "1340.0",   # decimal string; nil for source_gone
    #     "current_amount"  => "1100.0",   # decimal string
    #     "relative"        => "0.2182",   # nil when current amount is zero
    #     "basis"           => "source_rederive",
    #     "computed_at"     => "2026-06-12T10:00:00Z"
    #   }
    #
    # `relative` is nil when the current amount is zero — and zero-current
    # with a positive proposal ALWAYS counts as drifted: that is the live
    # recovery path for a card that seeded at $0.
    #
    # Runs only from ForecastDriftScanJob — never on a GET (spec §11 rule:
    # no derivation/drift computation on the GET path).
    class Scanner
      THRESHOLD = BigDecimal("0.15")
      DISMISS_TOLERANCE = BigDecimal("0.01")
      # How the verdict was computed: the scanner RE-DERIVES from the
      # assumption's linked source via Forecasts::Derivation — it does not
      # average trailing-3-month actuals.
      BASIS = "source_rederive"

      # Kinds Derivation knows how to re-derive; other kinds never nudge.
      PROPOSAL_METHODS = {
        "salary" => :salary_proposal,
        "living_expense" => :living_expense_proposal
      }.freeze

      def initialize(plan:, as_of:)
        @plan = plan
        @as_of = as_of.to_date
      end

      def scan!
        # Capture the key BEFORE scanning: if data changes mid-scan, the
        # stored key is already stale and the next GET triggers a follow-up.
        key = Forecasts::Drift.scan_key(plan)
        derivation = Forecasts::Derivation.new(family: plan.family, as_of: as_of)

        linked_assumptions.find_each do |assumption|
          method = PROPOSAL_METHODS[assumption.kind]
          next unless method

          proposal = derivation.public_send(method, existing: assumption)
          # Re-derive can return nil (median fallback at zero) — nothing to compare against.
          next if proposal.nil?

          write_drift(assumption, proposal)
        end

        plan.update_columns(drift_scan_key: key)
      end

      private
        attr_reader :plan, :as_of

        # Median-fallback source-less rows (source_record_id nil) are NOT
        # linked — they carry needs_review instead and never drift-nudge.
        # drift_silenced_at is the permanent "dismiss forever" switch.
        def linked_assumptions
          plan.forecast_assumptions
            .where(status: "active", origin: "source_derived", drift_silenced_at: nil)
            .where.not(source_record_id: nil)
        end

        def write_drift(assumption, proposal)
          payload =
            if proposal.status == :source_gone
              source_gone_payload(assumption)
            else
              drifted_payload(assumption, proposal)
            end

          # update_columns on purpose: drift writes must neither bump
          # lock_version (a plain update! would 409 an open drawer save)
          # nor touch updated_at (which feeds Forecasts::Drift.scan_key —
          # bumping it would mark the scan stale again and re-trigger a
          # scan on every subsequent GET, forever).
          return if payload.nil? && assumption.drift.nil?
          assumption.update_columns(drift: payload)
        end

        def source_gone_payload(assumption)
          {
            "status" => "source_gone",
            "proposed_amount" => nil,
            "current_amount" => decimal_string(current_amount(assumption)),
            "relative" => nil,
            "basis" => BASIS,
            "computed_at" => Time.current.iso8601
          }
        end

        # Returns the drift hash, or nil when the assumption is not (or no
        # longer) drifted — nil clears any stale verdict.
        def drifted_payload(assumption, proposal)
          current = current_amount(assumption)
          proposed = proposal.amount

          if current.zero?
            return nil unless proposed.positive?
            relative = nil
          else
            relative = (proposed - current).abs / current.abs
            return nil if relative < THRESHOLD
          end

          return nil if soft_dismissed?(assumption, proposed)

          {
            "status" => "drifted",
            "proposed_amount" => decimal_string(proposed),
            "current_amount" => decimal_string(current),
            "relative" => relative&.round(4)&.to_s("F"),
            "basis" => BASIS,
            "computed_at" => Time.current.iso8601
          }
        end

        # Soft dismiss: the user waved off a specific proposed amount; the
        # nudge stays hidden while the proposal hasn't moved.
        def soft_dismissed?(assumption, proposed)
          dismissed = assumption.drift_dismissed_amount
          dismissed.present? && (proposed - dismissed).abs < DISMISS_TOLERANCE
        end

        # Nil amount is treated as zero so a blank seeded card still gets
        # the zero-current recovery path.
        def current_amount(assumption)
          assumption.amount || BigDecimal("0")
        end

        # BigDecimal#to_s defaults to scientific notation ("0.134e4");
        # "F" keeps the documented "1340.0" shape.
        def decimal_string(value)
          BigDecimal(value.to_s).to_s("F")
        end
    end
  end
end
