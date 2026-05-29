module Forecast
  # Reconciliation of expected forecast events against actual ledger entries.
  # Inherits the family-scoped base controller, so every lookup goes through
  # `Current.family.forecast_event_links` (and the family's events/entries). A
  # cross-family link id therefore raises ActiveRecord::RecordNotFound (-> 404)
  # instead of trusting params[:id]; a foreign event/entry id is rejected by the
  # model's `records_belong_to_family` validation (-> 422).
  #
  # Lifecycle (the link, NOT the event, owns occurrence lifecycle):
  #   create  -> accept a candidate: build an accepted ForecastEventLink that
  #              snapshots the event + entry (the model enforces transaction-only
  #              entries, occurrence presence, and one-accepted-per-(event,
  #              occurrence)/per-entry uniqueness).
  #   update  -> change a link's status (reject / supersede). The model forbids
  #              changing the linked records/snapshots of an already-accepted
  #              link (-> 422), so only the status transition is permitted here.
  #   destroy -> remove a link.
  class EventLinksController < BaseController
    before_action :set_link, only: %i[update destroy]

    # GET /forecast/event_links
    # Renders the Reconciliation tab: events with their derived lifecycle state
    # plus, for unmatched occurrences, candidate actuals and an accepted link's
    # variance. Reuses the workspace query so the tab and any standalone render
    # cannot diverge.
    def index
      @workspace = Forecast::Workspace.new(family: @family)
      @reconciliation = @workspace.reconciliation
    end

    # POST /forecast/event_links
    # Accept a candidate actual for an event occurrence. The event and entry are
    # resolved THROUGH the family association so a foreign id is a 404; the model
    # is the server-side backstop for family membership and the accepted-link
    # invariants.
    def create
      @event = @family.forecast_events.find(create_params[:forecast_event_id])
      @entry = @family.entries.find(create_params[:entry_id])

      @link = @family.forecast_event_links.new(
        forecast_event: @event,
        entry: @entry,
        occurrence_on: create_params[:occurrence_on].presence || @event.starts_on,
        link_type: create_params[:link_type].presence || "actual",
        status: "accepted",
        confidence: create_params[:confidence],
        match_metadata: match_metadata_param
      )

      if @link.save
        redirect_to forecast_event_links_path, notice: t(".success")
      else
        redirect_to forecast_event_links_path, alert: link_error_message(@link)
      end
    end

    # PATCH/PUT /forecast/event_links/:id
    # Transition a link's status only (reject / supersede). The model forbids
    # mutating an accepted link's linked records/snapshots, so attempting to
    # repoint entry/event on an accepted link surfaces a 422.
    def update
      if @link.update(update_params)
        redirect_to forecast_event_links_path, notice: t(".success")
      else
        redirect_to forecast_event_links_path, alert: link_error_message(@link)
      end
    end

    # DELETE /forecast/event_links/:id
    def destroy
      @link.destroy
      redirect_to forecast_event_links_path, notice: t(".success")
    end

    private
      def set_link
        @link = @family.forecast_event_links.find(params[:id])
      end

      # Strong params for accepting a candidate. family_id is NEVER permitted
      # (set server-side via the family association). forecast_event_id and
      # entry_id are resolved through the family association in the action, and
      # the model's records_belong_to_family validation is the backstop.
      def create_params
        params.require(:forecast_event_link).permit(
          :forecast_event_id, :entry_id, :occurrence_on, :link_type, :confidence
        )
      end

      # Only the status transition is user-settable on update; the linked records
      # and snapshots are immutable once accepted (model-enforced). Restrict to
      # the non-accepted transitions a user drives from the UI.
      def update_params
        permitted = params.require(:forecast_event_link).permit(:status)
        permitted.slice(:status)
      end

      # Echo the candidate's scoring rationale into the link's match_metadata so
      # the accepted link records why it was proposed. Falls back to {} when the
      # candidate carried no metadata.
      def match_metadata_param
        raw = params.dig(:forecast_event_link, :match_metadata)
        return {} if raw.blank?

        raw.permit(:confidence, :confidence_level, :matched_at, reasons: []).to_h
      end

      def link_error_message(link)
        link.errors.full_messages.to_sentence.presence || t(".error")
      end
  end
end
