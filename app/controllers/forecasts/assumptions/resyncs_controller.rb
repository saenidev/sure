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
      include Forecasts::WorkspacePatching

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

      # create (POST) is the ACCEPT: re-runs Derivation server-side — the form
      # submits only expected_lock_version, so derived values are NEVER trusted
      # from the client — applies the proposal, and then runs EXACTLY the
      # drawer save's post-save flow (snapshot reuse, in-memory compute, async
      # persist, fresh lock header, workspace patch streams) via
      # Forecasts::WorkspacePatching.
      #
      # Accepted gap (sanctioned): resync accepts do not fire the undo toast —
      # forecast:assumption-saved is dispatched by the drawer's auto-submit
      # Stimulus controller only, and accepting a proposal is an explicit,
      # user-confirmed action.
      def create
        proposal = derive_proposal
        if proposal.nil? || proposal.source_gone?
          return render status: :unprocessable_entity,
            turbo_stream: card_stream(resync_state: :source_gone, proposal: nil)
        end

        return render_stale_lock if stale_lock?

        Forecasts::Plan.transaction do
          # Name intentionally kept: the user may have renamed the card; an
          # accept updates the figure and provenance, never the label.
          @assumption.update!(
            amount: proposal.amount,
            currency: proposal.currency,
            params: proposal.params,
            confidence: proposal.confidence,
            source_record_type: proposal.source_record&.class&.name,
            source_record_id: proposal.source_record&.id,
            source_refs: proposal.source_refs,
            derived_at: Time.current,
            review_state: :confirmed,
            # Accepting IS resolving the nudge: drop the cached drift verdict
            # and the soft-dismiss sentinel so the streamed card comes back
            # clean and the next scan starts from the freshly accepted figure.
            drift: nil,
            drift_dismissed_amount: nil
          )
          @plan.increment!(:current_plan_version)
        end

        snapshot = save_snapshot
        result = compute_projection(snapshot)
        enqueue_projection_persist(snapshot)
        write_assumption_lock_header
        render turbo_stream: workspace_patch_streams(result, snapshot: snapshot)
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
              (proposal.amount - (@assumption.amount || 0)).abs < AMOUNT_TOLERANCE
            :in_sync
          else
            :proposal
          end
        end

        # The accept form carries the lock token the proposal card was rendered
        # with; any concurrent save (drawer or another accept) bumps
        # lock_version and stales it.
        def stale_lock?
          params[:expected_lock_version].to_s != @assumption.lock_version.to_s
        end

        # Spec §4.6: on a stale lock the server state wins VISIBLY — 409 plus
        # the standard workspace patch streams (card, lock token, projection
        # from the last good cache), the same restream behavior the drawer's
        # update action uses.
        def render_stale_lock
          render status: :conflict, turbo_stream: workspace_patch_streams(nil)
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
