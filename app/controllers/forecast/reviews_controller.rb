module Forecast
  # Approval / edit / reject workflow for a forecast run group's review shell.
  #
  # There is exactly one ForecastReview per ForecastRunGroup (the mutable
  # approval shell that wraps an IMMUTABLE run group). The review is always
  # reached through `Current.family.forecast_run_groups.find(...) ->
  # forecast_review`, so a cross-family run-group id raises RecordNotFound (404)
  # and a foreign user can never load or mutate another family's review.
  #
  # The run group output itself stays immutable (the model enforces it); this
  # controller only ever transitions the review's `status` and approves Hermes
  # draft suggestions into real, user-owned ForecastScenarios (which start
  # disabled + approval_status approved, so a Hermes draft never auto-activates —
  # the Hermes approval boundary).
  class ReviewsController < BaseController
    before_action :set_run_group
    before_action :set_review, except: :show

    # GET /forecast/reviews/:id
    # Renders the review surface: deterministic facts + risk flags + any stored
    # Hermes response_packet (draft scenarios / events / recommendations /
    # follow-up questions) + status controls. Builds the review on demand if the
    # group somehow has none (older groups), so the page is never blank.
    def show
      @review = @run_group.forecast_review || build_review_for(@run_group)
    end

    # PATCH /forecast/reviews/:id
    # Transition the review status (draft -> awaiting_approval ->
    # approved/rejected/applied/superseded). Strong params permit ONLY :status;
    # the model's inclusion validation rejects arbitrary values with a 422. The
    # run group is never touched.
    def update
      if @review.update(review_params.merge(status_transition_timestamps))
        redirect_to forecast_review_path(@run_group), notice: t(".success")
      else
        respond_to do |format|
          format.html { render :show, status: :unprocessable_entity }
          format.json { render json: { errors: @review.errors.full_messages }, status: :unprocessable_entity }
        end
      end
    end

    # POST /forecast/reviews/:id/submit_to_hermes
    # Builds the deterministic packet, persists it onto the review's
    # request_packet, and hands it to the (stubbed) HermesClient. The external
    # round-trip is the EXCLUDED boundary: with no endpoint configured the client
    # raises NotConfigured, which we surface as a graceful notice (not a 500).
    def submit_to_hermes
      packet = Forecast::PacketBuilder.new(@run_group).build
      @review.update!(request_packet: packet)

      response_packet = Forecast::HermesClient.new.submit(packet)
      @review.update!(response_packet: @review.response_packet.merge(response_packet)) if response_packet.present?

      redirect_to forecast_review_path(@run_group), notice: t(".success")
    rescue Forecast::HermesClient::NotConfigured, Forecast::HermesClient::RequestFailed
      # Stubbed/unavailable external boundary: the packet is still built + saved,
      # so the review is ready to send the moment Hermes is wired up.
      redirect_to forecast_review_path(@run_group), notice: t(".not_configured")
    rescue Forecast::PacketBuilder::IncompleteRunGroup
      redirect_to forecast_review_path(@run_group), alert: t(".incomplete")
    end

    # POST /forecast/reviews/:id/approve_draft
    # Converts ONE Hermes draft scenario (from the review's stored
    # response_packet) into a real, editable ForecastScenario owned by
    # Current.family. The new scenario is created with approval_status "approved"
    # but status "disabled" — it is inert until the user toggles it on, so a
    # Hermes draft NEVER auto-activates (the Hermes approval boundary). Child
    # draft events are copied onto it (disabled).
    #
    # The draft is located by index within the stored response_packet, so a
    # foreign payload can never inject a scenario into another family: family is
    # always set server-side from Current.family.
    def approve_draft
      draft = draft_scenario_at(params[:draft_index])

      if draft.nil?
        redirect_to forecast_review_path(@run_group), alert: t(".draft_not_found")
        return
      end

      scenario = create_scenario_from_draft!(draft)
      redirect_to forecast_review_path(@run_group), notice: t(".success", name: scenario.name)
    rescue ActiveRecord::RecordInvalid => e
      redirect_to forecast_review_path(@run_group), alert: t(".error", message: e.record.errors.full_messages.to_sentence)
    end

    private
      def set_run_group
        # Eager-load the runs + their months/projections/goal evaluations so the
        # packet builder and the facts panel never N+1 over runs x months x
        # projections.
        @run_group = @family.forecast_run_groups
          .includes(
            :forecast_review,
            forecast_runs: [
              :forecast_goal_evaluations,
              { forecast_months: [ :forecast_category_projections, :forecast_debt_projections ] }
            ]
          )
          .find(params[:id])
      end

      def set_review
        @review = @run_group.forecast_review || build_review_for(@run_group)
      end

      # Build (and persist) a draft review for a group that has none. Source is
      # the group's run_type so the shell reflects how the run was triggered.
      def build_review_for(group)
        group.create_forecast_review!(
          family: @family,
          user: Current.user,
          source: ForecastReview::SOURCES.include?(group.run_type) ? group.run_type : "manual",
          status: "draft"
        )
      end

      # Strong params: ONLY :status is settable. family_id / user_id /
      # forecast_run_group_id / request_packet / response_packet are NEVER
      # mass-assignable here, so a status transition cannot smuggle in foreign
      # data or reparent the immutable run group.
      def review_params
        params.require(:forecast_review).permit(:status)
      end

      # Stamp approved_at / rejected_at when transitioning into those terminal
      # states so the review records WHEN the human decision happened. Returns an
      # empty hash for non-terminal transitions.
      def status_transition_timestamps
        case review_params[:status]
        when "approved" then { approved_at: Time.current }
        when "rejected" then { rejected_at: Time.current }
        else {}
        end
      end

      # Fetch the Nth draft scenario from the review's stored response_packet.
      # Returns nil for a missing/out-of-range index so approve_draft surfaces a
      # clear "not found" rather than a 500.
      def draft_scenario_at(index)
        drafts = Array(@review.response_packet["draft_scenarios"])
        i = Integer(index, exception: false)
        return nil if i.nil? || i.negative? || i >= drafts.size

        draft = drafts[i]
        draft.is_a?(Hash) ? draft : nil
      end

      # Materialize a draft scenario into a real, family-owned ForecastScenario.
      # Mirrors the slice-4 duplicate/deep-copy contract: created disabled so it
      # is inert, with approval_status "approved" (the human approved this Hermes
      # draft). family + created_by_user are set server-side. Child draft events
      # are copied as disabled events. Runs in a transaction so a single invalid
      # child rolls the whole approval back rather than leaving a partial copy.
      def create_scenario_from_draft!(draft)
        ForecastScenario.transaction do
          scenario = @family.forecast_scenarios.create!(
            name: draft["name"].presence || t("forecast.reviews.draft_scenario.default_name"),
            description: draft["description"],
            status: "disabled",
            approval_status: "approved",
            starts_on: draft["starts_on"],
            ends_on: draft["ends_on"],
            created_by_user: Current.user,
            source_metadata: { "hermes_review_id" => @review.id, "source" => "hermes_draft" }
          )

          Array(draft["events"]).each do |event|
            next unless event.is_a?(Hash)

            scenario.forecast_events.create!(
              family: @family,
              name: event["name"].presence || t("forecast.reviews.draft_scenario.default_event_name"),
              description: event["description"],
              effect_type: event["effect_type"],
              behavior: "additive",
              amount: event["amount"],
              currency: event["currency"].presence || @run_group.currency,
              starts_on: event["starts_on"].presence || @run_group.horizon_start_on,
              ends_on: event["ends_on"],
              status: "disabled",
              source_metadata: { "source" => "hermes_draft" }
            )
          end

          scenario
        end
      end
  end
end
