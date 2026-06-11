# frozen_string_literal: true

module Forecasts
  # Plan-workspace assumption editing. Family-scoped through Current.family on
  # every query — an id from another family is a 404, never a 403 leak.
  #
  # update is the auto-save endpoint (spec §4.6/§11, plan Amendment A:
  # compute-synchronous, persist-async): validate via the kind's typed form,
  # persist + bump the plan version in one transaction, run the engine IN
  # MEMORY (anchored at today, §10, reusing the current cache's source
  # snapshot — a save edits assumptions, not source data), respond with ONE
  # Turbo Stream that patches the projection region (which embeds the island),
  # the card, and the issue banner, then enqueue ForecastProjectionPersistJob
  # AFTER the transaction to write the cache off-request. A failed compute
  # keeps the save and leaves the last good projection on screen — never a
  # raw error.
  class AssumptionsController < ApplicationController
    include Forecasts::WorkspacePatching

    before_action :set_assumption

    def edit
      @form_partial = "forecasts/assumptions/form_#{@assumption.kind}"
    end

    def update
      form_class = Forecasts::Assumptions::Registry.form_class_for(@assumption.kind)
      return head :unprocessable_entity if form_class.nil?

      form = form_class.new(
        family: Current.family, plan: @plan, params: assumption_params, assumption: @assumption
      )

      return render_form_errors(form) unless form.valid?

      Forecasts::Plan.transaction do
        # An explicit edit resolves/invalidates any pending drift nudge: the
        # cached verdict's "current_amount" no longer matches, so drop the
        # cached drift verdict and the soft-dismiss sentinel. The next scan
        # re-evaluates fresh against the saved figure.
        @assumption.update!(form.assumption_attributes.merge(drift: nil, drift_dismissed_amount: nil))
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
        @assumption = Current.family.forecast_assumptions.find_by(id: params[:id])
        return head :not_found if @assumption.nil?

        @plan = @assumption.forecast_plan
      end

      # Submitted params merged OVER the assumption's stored values. The drawer
      # partials submit only a subset of the typed form's required fields
      # (name/amount/frequency/policy/currency/lock), so a partial submit must
      # never blank out a stored required param (person_key, gross_or_net,
      # actualization_policy, ...): any field the client did not send falls back
      # to the persisted columns / params jsonb. A field that IS submitted —
      # even blank — wins, so a user can still clear an optional value.
      def assumption_params
        submitted = params.require(:assumption).permit(
          :name, :amount, :currency, :person_key, :gross_or_net, :frequency,
          :growth_policy, :growth_rate, :net_ratio, :cash_account_id,
          :inflation_policy, :inflation_rate, :actualization_policy,
          :starts_on, :ends_on, :starts_at_milestone_id, :ends_at_milestone_id,
          :expected_lock_version, category_ids: []
        ).to_h

        stored_form_input.merge(submitted)
      end

      # The assumption re-expressed as raw form input: top-level columns for
      # the shared fields, params jsonb for the kind-specific ones. Keys the
      # assumption has no value for are compacted away so they stay "missing"
      # (not blank) for the form's validations.
      def stored_form_input
        stored = @assumption.params.is_a?(Hash) ? @assumption.params : {}

        {
          "name" => @assumption.name,
          "amount" => @assumption.amount,
          "currency" => @assumption.currency,
          "starts_on" => @assumption.starts_on,
          "ends_on" => @assumption.ends_on,
          "starts_at_milestone_id" => @assumption.starts_at_milestone_id,
          "ends_at_milestone_id" => @assumption.ends_at_milestone_id,
          "person_key" => stored["person_key"],
          "gross_or_net" => stored["gross_or_net"],
          "frequency" => stored["frequency"],
          "growth_policy" => stored["growth_policy"],
          "growth_rate" => stored["growth_rate"],
          "net_ratio" => stored["net_ratio"],
          "cash_account_id" => stored["cash_account_id"],
          "inflation_policy" => stored["inflation_policy"],
          "inflation_rate" => stored["inflation_rate"],
          "actualization_policy" => stored["actualization_policy"],
          "category_ids" => stored["category_ids"]
        }.compact
      end

      # Validation failure: 422 + re-render the drawer form (update keeps the
      # #forecast_drawer_form wrapper alive) with errors. A stale lock — BaseForm
      # puts code "stale_version" on :base — is a 409, and per spec §4.6 the
      # server state wins VISIBLY: the workspace patch streams ride along so the
      # page and the drawer's lock token reflect the server.
      def render_form_errors(form)
        @form_partial = "forecasts/assumptions/form_#{@assumption.kind}"
        stale = form.error_codes_for(:base).include?("stale_version")
        @assumption.reload if stale

        streams = [
          turbo_stream.update(
            "forecast_drawer_form",
            partial: @form_partial,
            locals: { assumption: @assumption, plan: @plan, form_object: form }
          )
        ]
        streams.concat(workspace_patch_streams(nil)) if stale

        render status: (stale ? :conflict : :unprocessable_entity), turbo_stream: streams
      end
  end
end
