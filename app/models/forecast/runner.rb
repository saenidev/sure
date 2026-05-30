module Forecast
  class Runner
    def initialize(family:, user:, scenario_stacks:, run_type:, name:, start_on: Date.current, trigger_metadata: {}, run_group: nil)
      @family = family
      @user = user
      @scenario_stacks = scenario_stacks
      @run_type = run_type
      @name = name
      @start_on = start_on
      @trigger_metadata = trigger_metadata
      @run_group = run_group
    end

    def call
      raise ArgumentError, "scenario_stacks must include at least one stack" if scenario_stacks.blank?

      group = create_group!
      create_review!(group) unless group.forecast_review
      group.update!(status: "running", started_at: Time.current)

      # Persist each scenario stack in its OWN transaction so a single stack
      # failure (e.g. a MissingRate FX error on one stack) rolls back only that
      # stack's rows, never its already-completed siblings. This is what makes
      # partial failure reachable: a group can end "failed" while still carrying
      # one or more "completed" runs, which the Comparison tab surfaces alongside
      # the failed stack instead of blanking the whole comparison.
      last_error = nil
      scenario_stacks.each do |scenario_ids|
        persist_stack!(group, scenario_ids)
      rescue StandardError => e
        last_error = e
      end

      finalize_group!(group, last_error)

      group
    rescue StandardError => e
      # A failure OUTSIDE per-stack persistence (group/review setup, or
      # finalize) still fails the whole group loudly.
      group&.update!(status: "failed", finished_at: Time.current, error_message: e.message)
      raise
    end

    private
      attr_reader :family, :user, :scenario_stacks, :run_type, :name, :start_on, :trigger_metadata, :run_group

      # Build + persist one scenario stack inside its own transaction so a raise
      # here rolls back only this stack's rows, never its completed siblings.
      #
      # On failure we record a lightweight, PERSISTED failed-run marker for the
      # stack (outside the rolled-back transaction) so the Comparison tab can show
      # WHICH stack failed alongside the ones that succeeded. The marker carries
      # only the stack identity + error; it has no day/month rows. The error is
      # re-raised so the caller records it and decides the group's terminal state.
      def persist_stack!(group, scenario_ids)
        stack = Forecast::ScenarioStack.new(family: family, scenario_ids: scenario_ids).call

        ApplicationRecord.transaction do
          input = Forecast::InputBuilder.new(family: family, user: user, scenario_ids: scenario_ids, start_on: start_on).call
          result = Forecast::Engine.new(input).call
          persist_run!(group, result)
        end
      rescue StandardError => e
        record_failed_run!(group, stack, e)
        raise
      end

      # Persist a failed-run marker for a stack whose persistence transaction
      # rolled back. Runs OUTSIDE that transaction so the marker survives. Best
      # effort: if even the marker cannot be written (e.g. the stack identity
      # could not be derived) we swallow that secondary error so the original
      # failure still propagates.
      def record_failed_run!(group, stack, error)
        return if stack.nil?

        group.forecast_runs.create!(
          family: family,
          user: user,
          scenario_stack_key: stack.key,
          scenario_stack_snapshot: stack.snapshot,
          status: "failed",
          feasibility_status: "unknown",
          currency: family.currency,
          started_at: Time.current,
          finished_at: Time.current,
          error_message: error.message
        )
      rescue StandardError
        nil
      end

      # Decide the group's terminal state from the runs that actually persisted.
      # Any completed run -> the group is usable (partial success); the failed
      # stacks remain visible in the Comparison tab. No completed run -> a true
      # total failure, which re-raises the last error so callers (jobs/console)
      # fail loudly as before.
      def finalize_group!(group, last_error)
        completed_runs = group.forecast_runs.reload.select { |run| run.status == "completed" }

        if completed_runs.empty?
          group.update!(
            status: "failed",
            finished_at: Time.current,
            error_message: last_error&.message || "Forecast runner produced no completed runs"
          )
          raise last_error if last_error
          raise "Forecast runner produced no completed runs"
        end

        group.update!(
          status: last_error ? "failed" : "completed",
          finished_at: Time.current,
          error_message: last_error&.message,
          source_data_versions: completed_runs.first&.input_snapshot&.fetch("source_data_versions", {}) || {},
          risk_flags: completed_runs.flat_map(&:risk_flags).uniq
        )
      end

      def create_group!
        return run_group if run_group.present?

        family.forecast_run_groups.create!(
          user: user,
          name: name,
          run_type: run_type,
          status: "pending",
          currency: family.currency,
          horizon_start_on: start_on,
          horizon_end_on: horizon_end_on,
          daily_until_on: start_on + 89.days,
          currency_snapshot: {
            "currency" => family.currency,
            "as_of" => start_on.iso8601
          },
          trigger_metadata: trigger_metadata
        )
      end

      def create_review!(group)
        group.create_forecast_review!(
          family: family,
          user: user,
          source: run_type,
          status: "draft",
          request_packet: {
            "run_group_id" => group.id,
            "run_type" => run_type,
            "name" => name,
            "scenario_stacks" => scenario_stacks,
            "horizon_start_on" => start_on.iso8601,
            "horizon_end_on" => horizon_end_on.iso8601,
            "trigger_metadata" => trigger_metadata
          }
        )
      end

      def horizon_end_on
        @horizon_end_on ||= Forecast::PeriodBuilder.new(family: family, start_on: start_on, months: 36, daily_days: 90).call.months.last.end_date
      end

      def persist_run!(group, result)
        run = group.forecast_runs.create!(
          family: family,
          user: user,
          scenario_stack_key: result.input.scenario_stack.key,
          scenario_stack_snapshot: result.input.scenario_stack.snapshot,
          status: "running",
          feasibility_status: "unknown",
          currency: result.input.currency,
          started_at: Time.current,
          input_snapshot: input_snapshot(result.input),
          source_contributions: result.source_contributions,
          risk_flags: result.risk_flags
        )

        result.days.each { |row| persist_day!(run, row) }
        result.months.each { |row| persist_month!(run, row) }
        result.goal_evaluations.each { |row| persist_goal_evaluation!(run, row) }

        run.update!(status: "completed", feasibility_status: result.feasibility_status, finished_at: Time.current)
      rescue StandardError => e
        run&.update!(status: "failed", finished_at: Time.current, error_message: e.message)
        raise
      end

      def input_snapshot(input)
        {
          "scenario_stack" => input.scenario_stack.snapshot,
          "currency" => input.currency,
          "source_data_versions" => input.source_data_versions,
          "portfolio" => input.portfolio,
          "accounts" => input.accounts.map { |account| account.fetch(:source_snapshot) },
          "budget_income" => input.budgets.map { |budget| budget.fetch(:income_source_snapshot) },
          "budget_categories" => input.budgets.flat_map { |budget| budget.fetch(:categories).map { |category| category.fetch(:source_snapshot) } },
          "recurring_items" => input.recurring_items.map { |row| row.fetch(:source_snapshot) },
          "pending_entries" => input.pending_entries.map { |row| row.fetch(:source_snapshot) },
          "forecast_events" => input.events.map { |event| event.fetch(:source_snapshot) },
          "debt_rows" => input.debt_rows.map { |row| row.fetch(:source_snapshot) },
          "liquidity_reclassifications" => reclassifications_for(input).map { |row| row.fetch(:source_snapshot) },
          "goals" => input.goals,
          "account_count" => input.accounts.size,
          "budget_period_count" => input.budgets.size,
          "recurring_item_count" => input.recurring_items.size,
          "pending_entry_count" => input.pending_entries.size,
          "forecast_event_count" => input.events.size,
          "liquidity_reclassification_count" => reclassifications_for(input).size,
          "goal_count" => input.goals.size
        }
      end

      def reclassifications_for(input)
        input.respond_to?(:reclassifications) ? Array(input.reclassifications) : []
      end

      def persist_day!(run, row)
        run.forecast_days.create!(
          date: row.date,
          scenario_stack_key: row.scenario_stack_key,
          currency: row.currency,
          expected_income: row.expected_income,
          expected_spending: row.expected_spending,
          pending_income: row.pending_income,
          pending_spending: row.pending_spending,
          cash_balance: row.cash_balance,
          liquid_balance: row.liquid_balance,
          portfolio_value: row.portfolio_value,
          debt_balance: row.debt_balance,
          net_worth: row.net_worth,
          cash_runway_days: row.cash_runway_days,
          liquid_runway_days: row.liquid_runway_days,
          source_breakdown: row.source_breakdown,
          risk_flags: row.risk_flags
        )
      end

      def persist_month!(run, row)
        month = run.forecast_months.create!(
          period_start_on: row.period_start_on,
          period_end_on: row.period_end_on,
          precision: row.precision,
          scenario_stack_key: row.scenario_stack_key,
          currency: row.currency,
          expected_income: row.expected_income,
          expected_spending: row.expected_spending,
          net_cash_flow: row.net_cash_flow,
          cash_balance: row.cash_balance,
          liquid_balance: row.liquid_balance,
          portfolio_value: row.portfolio_value,
          debt_balance: row.debt_balance,
          net_worth: row.net_worth,
          cash_runway_days: row.cash_runway_days,
          liquid_runway_days: row.liquid_runway_days,
          source_breakdown: row.source_breakdown,
          risk_flags: row.risk_flags
        )

        row.category_projections.each { |projection| persist_category_projection!(month, projection) }
        row.debt_projections.each { |projection| persist_debt_projection!(month, projection) }
      end

      def persist_category_projection!(month, projection)
        month.forecast_category_projections.create!(
          category_id: projection.fetch(:category_id),
          parent_category_id: projection.fetch(:parent_category_id),
          projection_key: projection.fetch(:projection_key),
          source: projection.fetch(:source),
          currency: projection.fetch(:currency),
          budgeted_spending: projection.fetch(:budgeted_spending),
          actual_spending: projection.fetch(:actual_spending),
          pending_spending: projection.fetch(:pending_spending),
          planned_spending: projection.fetch(:planned_spending),
          projected_spending_low: projection.fetch(:projected_spending_low),
          projected_spending_expected: projection.fetch(:projected_spending_expected),
          projected_spending_high: projection.fetch(:projected_spending_high),
          projected_spending: projection.fetch(:projected_spending),
          available_to_spend: projection.fetch(:available_to_spend),
          inherits_parent_budget: projection.fetch(:inherits_parent_budget),
          source_snapshot: projection.fetch(:source_snapshot),
          source_breakdown: projection.fetch(:source_breakdown),
          risk_flags: projection.fetch(:risk_flags)
        )
      end

      def persist_debt_projection!(month, projection)
        month.forecast_debt_projections.create!(
          account_id: projection.fetch(:account_id),
          debt_profile_id: projection.fetch(:debt_profile_id),
          projection_key: projection.fetch(:projection_key),
          currency: projection.fetch(:currency),
          opening_balance: projection.fetch(:opening_balance),
          projected_interest: projection.fetch(:projected_interest),
          projected_payment: projection.fetch(:projected_payment),
          cash_payment_gap: projection.fetch(:cash_payment_gap),
          projected_drawdown: projection.fetch(:projected_drawdown),
          ending_balance: projection.fetch(:ending_balance),
          source: projection.fetch(:source),
          risk_flags: projection.fetch(:risk_flags),
          source_snapshot: projection.fetch(:source_snapshot),
          source_breakdown: projection.except(:account_id, :debt_profile_id)
        )
      end

      def persist_goal_evaluation!(run, row)
        run.forecast_goal_evaluations.create!(
          forecast_goal_id: row.forecast_goal_id,
          goal_key: row.goal_key,
          scenario_stack_key: row.scenario_stack_key,
          status: row.status,
          currency: row.currency,
          metric_value: row.metric_value,
          target_value: row.target_value,
          evaluated_on: row.evaluated_on,
          goal_snapshot: row.goal_snapshot,
          details: row.details
        )
      end
  end
end
