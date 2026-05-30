module Forecast
  # Triggers and reports on forecast generation runs. Inherits the family-scoped
  # base controller, so every lookup goes through `Current.family` and a
  # cross-family run-group id raises RecordNotFound (-> 404).
  class RunsController < BaseController
    before_action :set_run_group, only: :status

    # Cap on how many scenario stacks one comparison run group may project. Each
    # stack is a full 90-day x 36-month x projection pass, so we bound the count
    # to keep memory/CPU sane (and the comparison UI legible). Baseline is always
    # one of the stacks, so this caps the total runs in the group.
    MAX_SCENARIO_STACKS = 5

    # POST /forecast/runs
    # Enqueues forecast generation off the request path. The actual Runner
    # (90 days + 36 months + projections, per stack) never runs inline here.
    #
    # Without a `scenario_stacks` param this enqueues a baseline-only run
    # (backwards compatible). With it, the user is composing a comparison: an
    # array of scenario-id arrays, one per stack. Baseline (`[]`) is always
    # included so the comparison has a reference line. Every submitted scenario
    # id MUST belong to Current.family or the whole request is rejected (422)
    # and nothing is enqueued — a foreign id never reaches the Runner.
    def create
      stacks = build_scenario_stacks
      return if stacks == :invalid

      run_start_on = Date.current
      group = reserve_pending_group!(
        name: t("forecasts.runs.default_name", date: l(run_start_on, format: :long)),
        start_on: run_start_on
      )
      return render_generation_in_flight if group == :in_flight

      ForecastGenerationJob.perform_later(run_group: group, scenario_stacks: stacks)

      redirect_to forecast_path, notice: t("forecasts.runs.enqueued")
    end

    # GET /forecast/runs/:id/status
    # Lightweight liveness endpoint the poller hits while a generation is in
    # flight. Scoped to the current family via set_run_group; another family's
    # id is a 404. Once the group reaches a terminal state we ask the poller to
    # reload the workspace so the user sees the result (or failure) immediately.
    def status
      respond_to do |format|
        format.json do
          render json: {
            id: @run_group.id,
            status: @run_group.status,
            done: @run_group.completed? || @run_group.failed?
          }
        end
      end
    end

    private
      # Block a second generation while one is pending or running for this
      # family, so we never stack duplicate runs.
      def generation_in_flight?
        @family.forecast_run_groups.where(status: %w[pending running]).exists?
      end

      # Reserve the run group synchronously inside a family row lock before
      # enqueuing. That closes the request/job-start race where two rapid submits
      # could both pass generation_in_flight? before the first worker created its
      # pending group.
      def reserve_pending_group!(name:, start_on:)
        @family.with_lock do
          return :in_flight if generation_in_flight?

          @family.forecast_run_groups.create!(
            user: Current.user,
            name: name,
            run_type: "manual",
            status: "pending",
            currency: @family.currency,
            horizon_start_on: start_on,
            horizon_end_on: Forecast::PeriodBuilder.new(family: @family, start_on: start_on, months: 36, daily_days: 90).call.months.last.end_date,
            daily_until_on: start_on + 89.days,
            currency_snapshot: {
              "currency" => @family.currency,
              "as_of" => start_on.iso8601
            }
          )
        end
      end

      def render_generation_in_flight
        respond_to do |format|
          format.html { redirect_to forecast_path, alert: t("forecasts.runs.already_running") }
          format.json { render json: { error: t("forecasts.runs.already_running") }, status: :conflict }
        end
      end

      # Normalize and validate the submitted scenario stacks. Returns the
      # cleaned `scenario_stacks` array on success, or `:invalid` after rendering
      # a 422 — in which case the caller must stop (nothing is enqueued).
      #
      # Rules enforced here (the production/authorization bar):
      #   * Empty/absent submission -> baseline-only `[[]]`.
      #   * Baseline (`[]`) is always present, deduped to the front.
      #   * Stack count (including baseline) is capped at MAX_SCENARIO_STACKS.
      #   * Every scenario id must belong to Current.family's *active* scenarios;
      #     any foreign/unknown id rejects the whole request (cross-family
      #     denial) before the Runner ever runs.
      def build_scenario_stacks
        raw_stacks = parse_scenario_stacks_param

        # Always include the baseline reference stack, deduped, at the front.
        normalized = ([ [] ] + raw_stacks).map { |ids| ids.uniq }.uniq

        if normalized.size > MAX_SCENARIO_STACKS
          return reject_stacks(t("forecasts.comparison.errors.too_many", max: MAX_SCENARIO_STACKS))
        end

        submitted_ids = normalized.flatten.uniq
        if submitted_ids.any?
          # Single family-scoped query: any id not returned is foreign/unknown.
          known_ids = @family.forecast_scenarios.active.where(id: submitted_ids).pluck(:id)
          unknown_ids = submitted_ids - known_ids
          if unknown_ids.any?
            return reject_stacks(t("forecasts.comparison.errors.unknown_scenarios"))
          end
        end

        normalized
      end

      # Pull the stacks out of params, tolerating both an array-of-arrays shape
      # and the Rails nested-hash shape the compose form submits
      # (`scenario_stacks[][scenario_ids][]`). Blank ids are dropped; an empty
      # stack maps to `[]` (baseline). Returns an array of arrays of id strings.
      def parse_scenario_stacks_param
        raw = params[:scenario_stacks]
        return [] if raw.blank?

        stacks = raw.respond_to?(:values) ? raw.values : Array(raw)

        stacks.filter_map do |stack|
          ids =
            if stack.respond_to?(:fetch) && (stack.key?("scenario_ids") || stack.key?(:scenario_ids))
              Array(stack[:scenario_ids] || stack["scenario_ids"])
            else
              Array(stack)
            end

          ids.map(&:to_s).compact_blank
        end
      end

      # Reject the submission with a 422 in every format and enqueue nothing.
      # For HTML we re-render the forecast workspace (so the user keeps their
      # page and sees the error) rather than redirecting, because a redirect
      # cannot carry the 422 status the comparison flow contract requires.
      def reject_stacks(message)
        respond_to do |format|
          format.html do
            @workspace = Forecast::Workspace.new(family: @family)
            @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("forecasts.show.title"), nil ] ]
            flash.now[:alert] = message
            render "forecasts/show", status: :unprocessable_entity
          end
          format.json { render json: { error: message }, status: :unprocessable_entity }
        end
        :invalid
      end
  end
end
