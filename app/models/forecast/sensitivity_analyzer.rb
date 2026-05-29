module Forecast
  # Deterministic single-variable sensitivity analysis over a built
  # InputBuilder::Result. Given a fixed, explicit catalog of one-at-a-time
  # perturbations (income -10%, expenses +10%, market return -X, debt rate
  # +200bps, ...), it re-runs Forecast::Engine ONCE per perturbation against a
  # deep clone of the input with a single coherent field group scaled, then
  # reports the delta in end-of-horizon cash_balance, net_worth, debt_balance,
  # the minimum projected cash runway, and any goal evaluation status changes
  # versus the unperturbed baseline.
  #
  # Invariants:
  # - Pure function over the input. The original input is NEVER mutated; every
  #   perturbation operates on a deep-duplicated clone.
  # - No wall-clock reads, no RNG, no DB-row-order dependence. The catalog is a
  #   fixed deterministic list, each entry applied independently, so identical
  #   inputs always yield identical, auditable results.
  # - This is the conservative, testable form of distribution analysis: genuine
  #   probabilistic sampling is deliberately excluded.
  class SensitivityAnalyzer
    Perturbation = Data.define(:key, :kind, :magnitude, :description)

    Result = Data.define(
      :perturbation_key,
      :kind,
      :magnitude,
      :description,
      :baseline_metric,
      :perturbed_metric,
      :delta,
      :goal_status_changes
    )

    # Fixed, deterministic catalog of single-variable perturbations. Each entry
    # scales exactly one coherent input dimension. Magnitudes are expressed as a
    # multiplicative factor relative to baseline (e.g. 0.9 == -10%). debt_rate is
    # expressed in basis points of additional annual interest applied to the
    # projected interest stream.
    DEFAULT_CATALOG = [
      Perturbation.new(key: "income_minus_10pct", kind: :income, magnitude: -0.10.to_d, description: "Income -10%"),
      Perturbation.new(key: "expenses_plus_10pct", kind: :expenses, magnitude: 0.10.to_d, description: "Expenses +10%"),
      Perturbation.new(key: "market_return_minus_20pct", kind: :market_return, magnitude: -0.20.to_d, description: "Market return -20%"),
      Perturbation.new(key: "debt_rate_plus_200bps", kind: :debt_rate, magnitude: 200.to_d, description: "Debt rate +200bps")
    ].freeze

    def initialize(input:, perturbations: DEFAULT_CATALOG)
      @input = input
      @perturbations = Array(perturbations)
    end

    def call
      return [] if perturbations.empty?

      baseline = Forecast::Engine.new(input).call
      baseline_metrics = metrics_for(baseline)
      baseline_statuses = goal_statuses_for(baseline)

      perturbations.map do |perturbation|
        perturbed_input = apply(perturbation, input)
        perturbed = Forecast::Engine.new(perturbed_input).call
        perturbed_metrics = metrics_for(perturbed)
        perturbed_statuses = goal_statuses_for(perturbed)

        Result.new(
          perturbation_key: perturbation.key,
          kind: perturbation.kind,
          magnitude: perturbation.magnitude,
          description: perturbation.description,
          baseline_metric: baseline_metrics,
          perturbed_metric: perturbed_metrics,
          delta: delta_for(baseline_metrics, perturbed_metrics),
          goal_status_changes: status_changes_for(baseline_statuses, perturbed_statuses)
        )
      end
    end

    private
      attr_reader :input, :perturbations

      # End-of-horizon metrics plus the worst (minimum) projected cash runway
      # across the whole horizon. Runway is min-not-last because a goal cares
      # about the trough, not the final month.
      def metrics_for(engine_result)
        last_month = engine_result.months.last
        runway_values = engine_result.months.filter_map(&:cash_runway_days)

        {
          "cash_balance" => last_month&.cash_balance.to_d,
          "net_worth" => last_month&.net_worth.to_d,
          "debt_balance" => last_month&.debt_balance.to_d,
          "minimum_cash_runway_days" => runway_values.min
        }
      end

      def delta_for(baseline_metrics, perturbed_metrics)
        baseline_metrics.each_with_object({}) do |(metric, baseline_value), deltas|
          perturbed_value = perturbed_metrics.fetch(metric)
          deltas[metric] = if baseline_value.nil? || perturbed_value.nil?
            # A nil runway means unbounded (no projected spend); a transition to
            # or from unbounded is not a finite numeric delta, so report nil and
            # let consumers read the raw baseline/perturbed values instead.
            metric == "minimum_cash_runway_days" && baseline_value == perturbed_value ? 0 : nil
          else
            perturbed_value - baseline_value
          end
        end
      end

      def goal_statuses_for(engine_result)
        engine_result.goal_evaluations.compact.each_with_object({}) do |evaluation, statuses|
          statuses[evaluation.forecast_goal_id] = evaluation.status
        end
      end

      def status_changes_for(baseline_statuses, perturbed_statuses)
        goal_ids = (baseline_statuses.keys + perturbed_statuses.keys).uniq
        goal_ids.filter_map do |goal_id|
          from = baseline_statuses[goal_id]
          to = perturbed_statuses[goal_id]
          next if from == to

          {
            "forecast_goal_id" => goal_id,
            "from" => from,
            "to" => to
          }
        end
      end

      # Build a perturbed clone of the input. Only the field groups touched by
      # the perturbation are deep-duplicated and rewritten; everything else is
      # carried over by reference (it is never mutated), so the original input is
      # untouched and the engine runs as a pure function over the clone.
      def apply(perturbation, original)
        case perturbation.kind
        when :income
          scale_income(original, factor: 1 + perturbation.magnitude)
        when :expenses
          scale_expenses(original, factor: 1 + perturbation.magnitude)
        when :market_return
          scale_market_return(original, factor: 1 + perturbation.magnitude)
        when :debt_rate
          shift_debt_rate(original, basis_points: perturbation.magnitude)
        else
          raise ArgumentError, "Unknown sensitivity perturbation kind: #{perturbation.kind.inspect}"
        end
      end

      # Income flows positively through expected_income and the cash/liquid/net
      # worth deltas of an effect row. Scaling income scales that whole coherent
      # group on income-bearing effect rows plus the budget expected_income.
      def scale_income(original, factor:)
        original.with(
          recurring_items: scale_income_rows(original.recurring_items, factor),
          pending_entries: scale_income_rows(original.pending_entries, factor),
          events: scale_income_rows(original.events, factor),
          budgets: scale_budget_income(original.budgets, factor)
        )
      end

      def scale_income_rows(rows, factor)
        rows.map do |row|
          income = row.fetch(:expected_income, 0).to_d
          next deep_dup(row) if income.zero?

          dup = deep_dup(row)
          scaled_income = scale(income, factor)
          income_delta = scaled_income - income
          dup[:expected_income] = scaled_income
          # Income raises cash/liquid/net worth; move the deltas by the same
          # signed amount so the engine's balance roll-forward stays coherent.
          dup[:cash_delta] = dup.fetch(:cash_delta, 0).to_d + income_delta
          dup[:liquid_delta] = dup.fetch(:liquid_delta, 0).to_d + income_delta
          dup[:net_worth_delta] = dup.fetch(:net_worth_delta, 0).to_d + income_delta
          dup
        end
      end

      def scale_budget_income(budgets, factor)
        budgets.map do |budget|
          dup = deep_dup(budget)
          dup[:expected_income] = scale(budget.fetch(:expected_income, 0).to_d, factor) if budget.key?(:expected_income)
          dup
        end
      end

      # Expenses flow negatively through expected_spending and the cash/liquid/net
      # worth deltas of an effect row, and through budgeted/projected spending on
      # budget category rows. Scaling expenses scales that whole coherent group.
      def scale_expenses(original, factor:)
        original.with(
          recurring_items: scale_expense_rows(original.recurring_items, factor),
          pending_entries: scale_expense_rows(original.pending_entries, factor),
          events: scale_expense_rows(original.events, factor),
          budgets: scale_budget_expenses(original.budgets, factor)
        )
      end

      def scale_expense_rows(rows, factor)
        rows.map do |row|
          spending = row.fetch(:expected_spending, 0).to_d
          next deep_dup(row) if spending.zero?

          dup = deep_dup(row)
          scaled_spending = scale(spending, factor)
          spending_delta = scaled_spending - spending
          dup[:expected_spending] = scaled_spending
          # Spending lowers cash/liquid/net worth; the delta on a spend row is
          # negative, so adding the (positive) growth in spend pushes it further
          # negative by exactly the extra spent.
          dup[:cash_delta] = dup.fetch(:cash_delta, 0).to_d - spending_delta
          dup[:liquid_delta] = dup.fetch(:liquid_delta, 0).to_d - spending_delta
          dup[:net_worth_delta] = dup.fetch(:net_worth_delta, 0).to_d - spending_delta
          if dup.key?(:pending_spending)
            dup[:pending_spending] = scale(dup.fetch(:pending_spending, 0).to_d, factor)
          end
          dup
        end
      end

      def scale_budget_expenses(budgets, factor)
        budgets.map do |budget|
          dup = deep_dup(budget)
          if dup.key?(:budgeted_uncategorized_spending)
            dup[:budgeted_uncategorized_spending] = scale(budget.fetch(:budgeted_uncategorized_spending, 0).to_d, factor)
          end
          dup[:categories] = Array(budget.fetch(:categories, [])).map do |category|
            category_dup = deep_dup(category)
            %i[budgeted_spending projected_spending_low projected_spending_expected projected_spending_high].each do |field|
              category_dup[field] = scale(category.fetch(field, 0).to_d, factor) if category.key?(field)
            end
            category_dup
          end
          dup
        end
      end

      # Market return moves the portfolio value and the portfolio_delta of any
      # effect row, and the matching net worth delta carried by those rows.
      def scale_market_return(original, factor:)
        original.with(
          portfolio: scale_portfolio(original.portfolio, factor),
          recurring_items: scale_portfolio_rows(original.recurring_items, factor),
          pending_entries: scale_portfolio_rows(original.pending_entries, factor),
          events: scale_portfolio_rows(original.events, factor)
        )
      end

      def scale_portfolio(portfolio, factor)
        dup = deep_dup(portfolio)
        dup[:portfolio_value] = scale(portfolio.fetch(:portfolio_value, 0).to_d, factor) if portfolio.key?(:portfolio_value)
        dup
      end

      def scale_portfolio_rows(rows, factor)
        rows.map do |row|
          portfolio_delta = row.fetch(:portfolio_delta, 0).to_d
          next deep_dup(row) if portfolio_delta.zero?

          dup = deep_dup(row)
          scaled_delta = scale(portfolio_delta, factor)
          dup[:portfolio_delta] = scaled_delta
          dup[:net_worth_delta] = dup.fetch(:net_worth_delta, 0).to_d + (scaled_delta - portfolio_delta)
          dup
        end
      end

      # Debt rate perturbation: add basis_points of additional annual interest to
      # each profile-backed debt projection row's projected interest, then carry
      # the extra interest into the ending balances cumulatively per account so a
      # higher rate deterministically raises end debt_balance. Balance-only
      # fallback rows (which never modeled interest) are left untouched so we do
      # not pretend interest was modeled where it was not.
      def shift_debt_rate(original, basis_points:)
        rate_factor = basis_points / 10_000.to_d # bps -> annual fraction
        carried_by_account = Hash.new(0.to_d)

        scaled_rows = original.debt_rows.map do |row|
          dup = deep_dup(row)
          next dup unless profile_backed?(row)

          account_id = row.fetch(:account_id, nil)
          opening = row.fetch(:opening_balance, 0).to_d
          # Extra interest for one period at the added annual rate, monthly.
          extra_interest = (opening * rate_factor / 12).round(6)
          carried = carried_by_account[account_id]

          new_interest = row.fetch(:projected_interest, 0).to_d + extra_interest
          new_ending = [ row.fetch(:ending_balance, 0).to_d + carried + extra_interest, 0.to_d ].max

          dup[:projected_interest] = new_interest
          dup[:ending_balance] = new_ending
          carried_by_account[account_id] = carried + extra_interest
          dup
        end

        original.with(debt_rows: scaled_rows)
      end

      def profile_backed?(row)
        row.fetch(:source, nil) == "debt_profile_snapshot"
      end

      def scale(value, factor)
        (value.to_d * factor).round(6)
      end

      # Recursively duplicate Hashes/Arrays so the clone shares no mutable
      # structure with the original. Numerics, Dates, Strings, booleans and nil
      # are treated as immutable leaves (we replace, never mutate, them).
      def deep_dup(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), copy| copy[k] = deep_dup(v) }
        when Array
          value.map { |element| deep_dup(element) }
        else
          value
        end
      end
  end
end
