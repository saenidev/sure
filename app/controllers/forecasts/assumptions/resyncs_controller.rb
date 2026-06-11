# frozen_string_literal: true

module Forecasts
  module Assumptions
    # Per-card "refresh from data" re-sync for source-derived assumptions.
    #
    # show (GET, turbo_stream) is a pure PREVIEW: it re-runs
    # Forecasts::Derivation against the assumption's linked source and replaces
    # the card with one of three sub-states — a proposal (current -> proposed +
    # Accept / Keep current), "already in sync", or "source gone". It never
    # writes. `?cancel=1` restreams the plain card (the Keep-current link).
    #
    # Family-scoped through Current.family on every query — an id from another
    # family is a 404, never a 403 leak. Only source-derived rows are
    # resyncable (the trigger is only rendered for them; the guard backs it).
    class ResyncsController < ApplicationController
      # Proposal/current amounts within a cent render as "already in sync".
      AMOUNT_TOLERANCE = BigDecimal("0.01")

      before_action :set_assumption

      def show
        return render turbo_stream: card_stream if params[:cancel].present?

        proposal = derive_proposal
        render turbo_stream: card_stream(
          resync_state: resync_state_for(proposal), proposal: proposal
        )
      end

      private
        def set_assumption
          @assumption = Current.family.forecast_assumptions.find_by(id: params[:assumption_id])
          return head :not_found if @assumption.nil?
          # Only derived rows carry a source to re-sync against.
          return head :unprocessable_entity unless @assumption.origin == "source_derived"

          @plan = @assumption.forecast_plan
        end

        # Server-side re-derive from the assumption's OWN linked source (or its
        # fallback basis). Registry kinds only; an unregistered kind has no
        # derivation and reads as source-gone downstream (nil).
        def derive_proposal
          derivation = Forecasts::Derivation.new(family: Current.family, as_of: Date.current)
          case @assumption.kind
          when "salary" then derivation.salary_proposal(existing: @assumption)
          when "living_expense" then derivation.living_expense_proposal(existing: @assumption)
          end
        end

        # nil (nothing derivable anymore) reads the same as a vanished source:
        # there is no figure to offer, so the card shows the neutral
        # source-gone message. Acknowledging/unlinking is Task 6's dismissal
        # endpoint — here we only render the message.
        def resync_state_for(proposal)
          return :source_gone if proposal.nil? || proposal.source_gone?

          if proposal.currency == @assumption.currency &&
              (proposal.amount - @assumption.amount).abs < AMOUNT_TOLERANCE
            :in_sync
          else
            :proposal
          end
        end

        def card_stream(resync_state: nil, proposal: nil)
          turbo_stream.replace(
            helpers.dom_id(@assumption),
            partial: "forecasts/assumption_card",
            locals: { assumption: @assumption, resync_state: resync_state, proposal: proposal }
          )
        end
    end
  end
end
