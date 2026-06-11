# frozen_string_literal: true

module Forecasts
  module Assumptions
    # Dismisses (or acknowledges) a drift nudge on an assumption card.
    #
    # Every write here uses update_columns ON PURPOSE: drift state is UI
    # bookkeeping, not a plan edit. A regular update! would bump lock_version
    # — instantly 409-ing an open editor drawer's next autosave — and touch
    # updated_at, making a dismissal look like a content change.
    #
    # - drifted + permanent=1 -> silence all future nudges (drift_silenced_at)
    # - drifted (soft)        -> remember the proposed amount so the scanner
    #                            only re-nudges on a DIFFERENT proposal
    # - source_gone (any)     -> acknowledge: drop the source link entirely;
    #                            the card becomes manual and the notice never
    #                            renders again
    # - no drift at all       -> idempotent no-op (double-click / stale card);
    #                            still re-streams the card so the client
    #                            converges on server state
    class DriftDismissalsController < ApplicationController
      before_action :set_assumption

      def create
        if @assumption.drift_source_gone?
          # Acknowledge makes the card GENUINELY manual: drop the live source
          # link AND flip origin so the "From your data" label and the
          # refresh-from-data trigger stop rendering. origin is a string-backed
          # enum, so writing the raw string through update_columns is safe.
          # source_refs is deliberately retained as history of where the
          # figure originally came from.
          @assumption.update_columns(
            source_record_type: nil, source_record_id: nil,
            origin: "user_created", drift: nil
          )
        elsif @assumption.drift_nudge?
          if params[:permanent] == "1"
            @assumption.update_columns(drift_silenced_at: Time.current, drift: nil)
          else
            @assumption.update_columns(
              drift_dismissed_amount: @assumption.drift_proposed_amount, drift: nil
            )
          end
        end

        render turbo_stream: turbo_stream.replace(
          helpers.dom_id(@assumption),
          partial: "forecasts/assumption_card",
          locals: { assumption: @assumption }
        )
      end

      private
        # Mirrors Forecasts::AssumptionsController#set_assumption: family-scoped
        # through Current.family, so a cross-family id is a 404 (never a 403
        # information leak).
        def set_assumption
          @assumption = Current.family.forecast_assumptions.find_by(id: params[:assumption_id])
          head :not_found if @assumption.nil?
        end
    end
  end
end
