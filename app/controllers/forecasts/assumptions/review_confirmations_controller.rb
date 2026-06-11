# frozen_string_literal: true

module Forecasts
  module Assumptions
    # "Looks right" on a needs_review card: the user vouches for a derived
    # assumption without opening the editor.
    #
    # update_columns ON PURPOSE: confirming is review bookkeeping, not a plan
    # edit — a regular save would bump lock_version (409-ing an open drawer's
    # next autosave) and updated_at. review_state is a string-backed enum and
    # update_columns bypasses enum casting, so the raw string is written.
    # Already-confirmed (double-click / stale card) is a no-op 200 that still
    # re-streams the card so the client converges.
    class ReviewConfirmationsController < ApplicationController
      before_action :set_assumption

      def create
        if @assumption.review_state == "needs_review"
          @assumption.update_columns(review_state: "confirmed")
        end

        render turbo_stream: turbo_stream.replace(
          helpers.dom_id(@assumption),
          partial: "forecasts/assumption_card",
          locals: { assumption: @assumption }
        )
      end

      private
        # Mirrors Forecasts::AssumptionsController#set_assumption: family-scoped,
        # cross-family ids are a 404.
        def set_assumption
          @assumption = Current.family.forecast_assumptions.find_by(id: params[:assumption_id])
          head :not_found if @assumption.nil?
        end
    end
  end
end
