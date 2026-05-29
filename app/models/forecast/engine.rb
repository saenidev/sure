module Forecast
  class Engine
    Result = Data.define(:input, :days, :months, :goal_evaluations, :feasibility_status, :risk_flags, :source_contributions)
    DayRow = Data.define(:date, :scenario_stack_key, :currency, :expected_income, :expected_spending, :pending_income, :pending_spending, :cash_balance, :liquid_balance, :portfolio_value, :debt_balance, :net_worth, :cash_runway_days, :liquid_runway_days, :source_breakdown, :risk_flags)
    MonthRow = Data.define(:period_start_on, :period_end_on, :precision, :scenario_stack_key, :currency, :expected_income, :expected_spending, :net_cash_flow, :cash_balance, :liquid_balance, :portfolio_value, :debt_balance, :net_worth, :cash_runway_days, :liquid_runway_days, :category_projections, :debt_projections, :source_breakdown, :risk_flags)

    def initialize(input)
      @input = input
      @scenario_stack_key = input.scenario_stack.key
    end

    def call
      day_rows = build_days
      month_rows = build_months(day_rows)
      evaluations = Forecast::GoalEvaluator.new(
        goals: input.goals,
        months: month_rows,
        scenario_stack_key: scenario_stack_key
      ).call

      Result.new(
        input: input,
        days: day_rows,
        months: month_rows,
        goal_evaluations: evaluations,
        feasibility_status: feasibility_status_for(evaluations),
        risk_flags: (input_risk_flags + risk_flags_for(evaluations) + month_rows.flat_map(&:risk_flags)).uniq,
        source_contributions: {
          "accounts" => input.accounts.size,
          "budget_periods" => input.budgets.size,
          "recurring_items" => input.recurring_items.size,
          "pending_entries" => input.pending_entries.size,
          "forecast_events" => input.events.size,
          "debt_rows" => input.debt_rows.size,
          "portfolio_holdings" => input.portfolio.fetch(:holdings, []).size,
          "goals" => input.goals.size
        }
      )
    end

    private
      attr_reader :input, :scenario_stack_key

      def build_days
        cash = opening_cash
        liquid = opening_liquid
        portfolio = opening_portfolio
        debt = opening_debt
        net_worth = opening_net_worth

        input.periods.days.map do |date|
          recurring_rows = rows_on(input.recurring_items, date)
          pending_rows = rows_on(input.pending_entries, date)
          event_rows = rows_on(input.events, date)
          effect_rows = recurring_rows + pending_rows + event_rows
          expected_income = sum_effect(effect_rows, :expected_income)
          expected_spending = sum_effect(effect_rows, :expected_spending)
          pending_income = sum_effect(pending_rows, :pending_income)
          pending_spending = sum_effect(pending_rows, :pending_spending)

          cash += sum_effect(effect_rows, :cash_delta)
          liquid += sum_effect(effect_rows, :liquid_delta)
          debt = [ debt + sum_effect(effect_rows, :debt_delta), 0.to_d ].max
          portfolio += sum_effect(effect_rows, :portfolio_delta)
          net_worth += sum_effect(effect_rows, :net_worth_delta)

          DayRow.new(
            date: date,
            scenario_stack_key: scenario_stack_key,
            currency: input.currency,
            expected_income: expected_income,
            expected_spending: expected_spending,
            pending_income: pending_income,
            pending_spending: pending_spending,
            cash_balance: cash,
            liquid_balance: liquid,
            portfolio_value: portfolio,
            debt_balance: debt,
            net_worth: net_worth,
            cash_runway_days: runway_days(cash),
            liquid_runway_days: runway_days(liquid),
            source_breakdown: { "phase" => "daily" },
            risk_flags: effect_rows.flat_map { |row| row.fetch(:risk_flags, []) }
          )
        end
      end

      def build_months(day_rows)
        cash = opening_cash
        liquid = opening_liquid
        portfolio = opening_portfolio
        debt = opening_debt
        net_worth = opening_net_worth
        debt_projection_adjustment = 0.to_d

        input.periods.months.map do |period|
          opening_debt_for_month = debt
          month_days = day_rows.select { |day| period.start_date <= day.date && day.date <= period.end_date }
          budget = input.budgets.find { |row| row.fetch(:period_start_on) == period.start_date }
          debt_projections = input.debt_rows.select { |row| row.fetch(:period_start_on) == period.start_date }
          recurring_rows = rows_between(input.recurring_items, period.start_date, period.end_date)
          pending_rows = rows_between(input.pending_entries, period.start_date, period.end_date)
          event_rows = rows_between(input.events, period.start_date, period.end_date)
          effect_rows = recurring_rows + pending_rows + event_rows
          category_projections = category_projection_rows(budget, period, effect_rows)
          debt_reconciliation = reconcile_debt_effects(debt_projections, recurring_rows, pending_rows, event_rows)
          debt_payment_gap = debt_reconciliation.fetch(:residual_cash_gap)
          debt_budget_credit = debt_payment_budget_credit_for(category_projections, debt_payment_gap)
          debt_payment_unbudgeted_cash_gap = debt_payment_gap - debt_budget_credit

          if daily_rows_cover_period?(month_days, period)
            last_day = month_days.last
            previous_day = day_rows.select { |day| day.date < month_days.first.date }.last
            base_cash = previous_day&.cash_balance || opening_cash
            base_liquid = previous_day&.liquid_balance || opening_liquid
            base_debt = previous_day&.debt_balance || opening_debt
            base_portfolio = previous_day&.portfolio_value || opening_portfolio
            base_net_worth = previous_day&.net_worth || opening_net_worth
            category_spending = category_projections.sum { |row| row.fetch(:projected_spending).to_d }
            uncategorized_budget_gap = uncategorized_budget_gap_for(budget, effect_rows)
            uncategorized_spend = uncategorized_spending(effect_rows) + uncategorized_budget_gap
            income = month_days.sum(&:expected_income)
            spending = category_spending + uncategorized_spend
            budget_income_gap = budget_income_gap_for(budget, income)
            already_applied_category_spending = applied_category_spending(category_projections)
            actual_already_reflected = actual_spending_already_reflected(category_projections, budget, period)
            budget_spend_gap = [ category_spending - actual_already_reflected - already_applied_category_spending - debt_budget_credit, 0.to_d ].max
            cash += last_day.cash_balance - base_cash
            liquid += last_day.liquid_balance - base_liquid
            debt = [ debt + (last_day.debt_balance - base_debt), 0.to_d ].max
            portfolio += last_day.portfolio_value - base_portfolio
            net_worth += last_day.net_worth - base_net_worth

            cash -= budget_spend_gap + uncategorized_budget_gap + debt_payment_gap
            liquid -= budget_spend_gap + uncategorized_budget_gap + debt_payment_gap
            cash += budget_income_gap
            liquid += budget_income_gap
            net_worth += budget_income_gap
            net_worth -= budget_spend_gap + uncategorized_budget_gap
            net_worth -= debt_payment_gap
          else
            actual_already_reflected = actual_spending_already_reflected(category_projections, budget, period)
            category_spending = category_projections.sum { |row| row.fetch(:projected_spending).to_d }
            uncategorized_budget_gap = uncategorized_budget_gap_for(budget, effect_rows)
            uncategorized_spend = uncategorized_spending(effect_rows) + uncategorized_budget_gap
            already_applied_category_spending = applied_category_spending(category_projections)
            budget_spend_gap = [ category_spending - actual_already_reflected - already_applied_category_spending - debt_budget_credit, 0.to_d ].max
            income = sum_effect(effect_rows, :expected_income)
            budget_income_gap = budget_income_gap_for(budget, income)
            spending = category_spending + uncategorized_spend
            cash += sum_effect(effect_rows, :cash_delta) + budget_income_gap - budget_spend_gap - uncategorized_budget_gap - debt_payment_gap
            liquid += sum_effect(effect_rows, :liquid_delta) + budget_income_gap - budget_spend_gap - uncategorized_budget_gap - debt_payment_gap
            debt = [ debt + sum_effect(effect_rows, :debt_delta), 0.to_d ].max
            portfolio += sum_effect(effect_rows, :portfolio_delta)
            net_worth += sum_effect(effect_rows, :net_worth_delta) + budget_income_gap - budget_spend_gap - uncategorized_budget_gap - debt_payment_gap
          end

          debt_projection_adjustment += debt_reconciliation.fetch(:projection_adjustment)
          debt_before_projection = debt
          debt_balance = if debt_projections.any?
            [ debt_projections.sum { |row| row.fetch(:ending_balance).to_d } + debt_projection_adjustment, 0.to_d ].max
          else
            debt
          end
          debt = debt_balance
          net_worth -= debt_balance - debt_before_projection
          total_debt_delta = debt_balance.to_d - opening_debt_for_month.to_d
          debt_to_cash_ratio = debt_to_cash_ratio_for(debt_balance, cash)
          cash_floor = minimum_cash_floor
          risk_flags = effect_rows.flat_map { |row| row.fetch(:risk_flags, []) } + debt_projections.flat_map { |row| row.fetch(:risk_flags, []) }
          risk_flags += debt_pressure_risk_flags(
            cash: cash,
            cash_floor: cash_floor,
            debt_payment_unbudgeted_cash_gap: debt_payment_unbudgeted_cash_gap,
            debt_projections: debt_projections
          )

          MonthRow.new(
            period_start_on: period.start_date,
            period_end_on: period.end_date,
            precision: period.precision,
            scenario_stack_key: scenario_stack_key,
            currency: input.currency,
            expected_income: income + budget_income_gap,
            expected_spending: spending,
            net_cash_flow: income + budget_income_gap - spending - debt_payment_unbudgeted_cash_gap,
            cash_balance: cash,
            liquid_balance: liquid,
            portfolio_value: portfolio,
            debt_balance: debt_balance,
            net_worth: net_worth,
            cash_runway_days: runway_days(cash),
            liquid_runway_days: runway_days(liquid),
            category_projections: category_projections,
            debt_projections: debt_projections,
            source_breakdown: {
              "budget_source" => budget&.fetch(:source_budget_id),
              "budget_income_gap" => budget_income_gap.to_s,
              "budget_spend_gap" => budget_spend_gap.to_s,
              "uncategorized_spending" => uncategorized_spend.to_s,
              "uncategorized_budget_gap" => uncategorized_budget_gap.to_s,
              "already_applied_category_spending" => already_applied_category_spending.to_s,
              "actual_spending_already_reflected" => actual_already_reflected.to_s,
              "debt_payment_cash_gap" => debt_payment_gap.to_s,
              "debt_payment_budget_credit" => debt_budget_credit.to_s,
              "debt_payment_unbudgeted_cash_gap" => debt_payment_unbudgeted_cash_gap.to_s,
              "debt_payment_effect_credit" => debt_reconciliation.fetch(:cash_payment_credit).to_s,
              "debt_projection_adjustment" => debt_projection_adjustment.to_s,
              "total_debt_delta" => total_debt_delta.to_s,
              "debt_to_cash_ratio" => debt_to_cash_ratio
            },
            risk_flags: risk_flags
          )
        end
      end

      def category_projection_rows(budget, period, effect_rows)
        budget_rows = budget&.fetch(:categories) || []
        budget_category_ids = budget_rows.map { |row| row.fetch(:category_id) }
        applied_by_category = categorized_spending_by_projection(effect_rows, budget_category_ids)
        pending_by_category = pending_spending_by_projection(effect_rows, budget_category_ids)
        event_by_category = event_category_spending_by_projection(period.start_date, period.end_date, budget_category_ids)
        debt_payment_by_category = debt_payment_spending_by_projection(effect_rows, budget_category_ids)

        inherited_rows = budget_rows.map do |category|
          category_id = category.fetch(:category_id)
          budgeted = category.fetch(:budgeted_spending).to_d
          actual = category.fetch(:actual_spending).to_d
          applied = applied_by_category.fetch(category_id, 0.to_d)
          pending = pending_by_category.fetch(category_id, 0.to_d)
          planned = event_by_category.fetch(category_id, 0.to_d)
          debt_payment_spending = debt_payment_by_category.fetch(category_id, 0.to_d)
          debt_payment_budget_row = debt_payment_budget_row?(category, debt_payment_spending)
          projected = [ actual + applied, budgeted + planned ].max
          distribution_low = category.fetch(:projected_spending_low, budgeted).to_d + planned
          distribution_high = category.fetch(:projected_spending_high, projected).to_d + planned
          committed_floor = actual + applied

          category.merge(
            source: category.fetch(:source, "budget_inheritance"),
            currency: input.currency,
            actual_spending: actual,
            pending_spending: pending,
            planned_spending: planned,
            projected_spending_low: [ distribution_low, committed_floor ].max,
            projected_spending_expected: projected,
            projected_spending_high: [ distribution_high, projected ].max,
            projected_spending: projected,
            available_to_spend: budgeted - projected,
            source_breakdown: {
              "budgeted" => budgeted.to_s,
              "actual" => actual.to_s,
              "applied_spending" => applied.to_s,
              "pending_spending" => pending.to_s,
              "debt_payment_spending" => debt_payment_spending.to_s,
              "debt_payment_budget_row" => debt_payment_budget_row,
              "planned" => planned.to_s,
              "distribution_source" => category.fetch(:distribution_source, "none")
            }
          )
        end

        inherited_category_ids = inherited_rows.map { |row| row.fetch(:category_id) }
        synthetic_rows = (applied_by_category.keys - inherited_category_ids).map do |category_id|
          applied = applied_by_category.fetch(category_id)
          pending = pending_by_category.fetch(category_id, 0.to_d)
          planned = event_by_category.fetch(category_id, 0.to_d)
          debt_payment_spending = debt_payment_by_category.fetch(category_id, 0.to_d)

          {
            category_id: category_id,
            parent_category_id: category_snapshot_for(category_id)&.fetch("parent_id", nil),
            projection_key: category_id,
            source: "forecast_effect",
            currency: input.currency,
            budgeted_spending: 0.to_d,
            actual_spending: 0.to_d,
            pending_spending: pending,
            planned_spending: planned,
            projected_spending_low: applied,
            projected_spending_expected: applied,
            projected_spending_high: applied,
            projected_spending: applied,
            available_to_spend: -applied,
            inherits_parent_budget: false,
            source_snapshot: {
              "category" => category_snapshot_for(category_id),
              "reason" => "forecast_effect_without_budget_category"
            },
            source_breakdown: {
              "budgeted" => "0.0",
              "actual" => "0.0",
              "applied_spending" => applied.to_s,
              "pending_spending" => pending.to_s,
              "debt_payment_spending" => debt_payment_spending.to_s,
              "debt_payment_budget_row" => debt_payment_spending.positive?,
              "planned" => planned.to_s,
              "distribution_source" => "forecast_effect"
            },
            risk_flags: [
              {
                "type" => "forecast_category_without_budget_row",
                "category_id" => category_id
              }
            ]
          }
        end

        inherited_rows + synthetic_rows
      end

      def opening_cash
        input.accounts.select { |account| account.fetch(:liquidity_class) == "cash" }.sum { |account| account.fetch(:balance).to_d }
      end

      def opening_liquid
        input.accounts.select { |account| account.fetch(:liquidity_class).in?(%w[cash liquid]) }.sum { |account| account.fetch(:balance).to_d }
      end

      def opening_debt
        input.accounts.select { |account| account.fetch(:classification) == "liability" }.sum { |account| account.fetch(:balance).to_d }
      end

      def opening_portfolio
        input.portfolio.fetch(:portfolio_value).to_d
      end

      def opening_net_worth
        input.accounts.select { |account| account.fetch(:classification) == "asset" }.sum { |account| account.fetch(:balance).to_d } - opening_debt
      end

      def rows_on(rows, date)
        rows.select { |row| row.fetch(:date) == date }
      end

      def rows_between(rows, start_date, end_date)
        rows.select { |row| start_date <= row.fetch(:date) && row.fetch(:date) <= end_date }
      end

      def daily_rows_cover_period?(month_days, period)
        return false if month_days.empty?

        dates = month_days.map(&:date)
        dates.min <= period.start_date && dates.max >= period.end_date
      end

      def sum_effect(rows, field)
        rows.sum { |row| row.fetch(field, 0).to_d }
      end

      def uncategorized_spending(rows)
        rows.select { |row| row.fetch(:budget_flow_type) == "expense" && row.fetch(:category_id, nil).blank? }
          .sum { |row| row.fetch(:expected_spending).to_d }
      end

      def uncategorized_budget_gap_for(budget, effect_rows)
        budgeted = budget.to_h.fetch(:budgeted_uncategorized_spending, 0).to_d
        return 0.to_d if budgeted.zero?

        actual = budget.to_h.fetch(:actual_uncategorized_spending, 0).to_d
        already_applied = uncategorized_spending(effect_rows)
        [ budgeted - actual - already_applied, 0.to_d ].max
      end

      def categorized_spending(rows)
        rows.select { |row| row.fetch(:budget_flow_type) == "expense" && row.fetch(:category_id, nil).present? }
          .sum { |row| row.fetch(:expected_spending).to_d }
      end

      def applied_category_spending(category_projections)
        category_projections.sum { |row| row.fetch(:source_breakdown).fetch("applied_spending", "0").to_d }
      end

      def debt_payment_budget_credit_for(category_projections, debt_payment_gap)
        return 0.to_d if debt_payment_gap <= 0

        available_budget = category_projections.select { |row| row.fetch(:source_breakdown, {}).fetch("debt_payment_budget_row", false) }.sum do |row|
          projected = row.fetch(:projected_spending).to_d
          actual = row.fetch(:actual_spending, 0).to_d
          applied = row.fetch(:source_breakdown, {}).fetch("applied_spending", "0").to_d

          [ projected - actual - applied, 0.to_d ].max
        end

        [ available_budget, debt_payment_gap ].min
      end

      def debt_payment_budget_row?(category, debt_payment_spending)
        debt_payment_spending.positive? ||
          actual_debt_payment_spending(category).positive? ||
          forecast_budget_override_marks_debt_payment?(category)
      end

      def actual_debt_payment_spending(category)
        entries = Array(category.fetch(:source_snapshot, {}).fetch("actual_spending_entries", []))
        entries.select { |entry| entry["effective_transaction_kind"] == "loan_payment" || entry["transaction_kind"] == "loan_payment" }
          .sum { |entry| entry.dig("money", "amount").to_d }
      end

      def forecast_budget_override_marks_debt_payment?(category)
        override_snapshot = category.fetch(:source_snapshot, {}).fetch("forecast_budget_override", {})
        ActiveModel::Type::Boolean.new.cast(override_snapshot.fetch("source_metadata", {}).fetch("debt_payment_credit", false))
      end

      def categorized_spending_by_projection(rows, budget_category_ids)
        rows.select { |row| row.fetch(:budget_flow_type) == "expense" && row.fetch(:category_id, nil).present? }
          .group_by { |row| projection_key_for(row.fetch(:category_id), budget_category_ids) }
          .transform_values { |category_rows| category_rows.sum { |row| row.fetch(:expected_spending).to_d } }
      end

      def pending_spending_by_projection(rows, budget_category_ids)
        rows.select { |row| row.fetch(:category_id, nil).present? }
          .group_by { |row| projection_key_for(row.fetch(:category_id), budget_category_ids) }
          .transform_values { |category_rows| category_rows.sum { |row| row.fetch(:pending_spending, 0).to_d } }
      end

      def event_category_spending_by_projection(start_date, end_date, budget_category_ids)
        input.events
          .select { |event| start_date <= event.fetch(:date) && event.fetch(:date) <= end_date }
          .select { |event| event.fetch(:category_id, nil).present? && event.fetch(:budget_flow_type) == "expense" }
          .group_by { |event| projection_key_for(event.fetch(:category_id), budget_category_ids) }
          .transform_values { |events| events.sum { |event| event.fetch(:expected_spending).to_d } }
      end

      def debt_payment_spending_by_projection(rows, budget_category_ids)
        rows.select { |row| row.fetch(:budget_flow_type) == "expense" && row.fetch(:category_id, nil).present? && row.fetch(:transaction_kind, nil) == "loan_payment" }
          .group_by { |row| projection_key_for(row.fetch(:category_id), budget_category_ids) }
          .transform_values { |category_rows| category_rows.sum { |row| row.fetch(:expected_spending).to_d } }
      end

      def projection_key_for(category_id, budget_category_ids)
        return category_id if budget_category_ids.include?(category_id)

        category = input.family.categories.find_by(id: category_id)
        return category.parent_id if category&.parent_id.present? && budget_category_ids.include?(category.parent_id)

        category_id
      end

      def category_snapshot_for(category_id)
        category = input.family.categories.find_by(id: category_id)
        return nil if category.blank?

        {
          "id" => category.id,
          "name" => category.name,
          "parent_id" => category.parent_id,
          "parent_name" => category.parent&.name
        }
      end

      def reconcile_debt_effects(debt_projections, _recurring_rows, pending_rows, event_rows)
        remaining_gap_by_account = debt_projections.each_with_object({}) do |row, hash|
          hash[row.fetch(:account_id, nil)] = row.fetch(:cash_payment_gap, 0).to_d
        end
        projected_account_ids = remaining_gap_by_account.keys.compact
        effect_rows = pending_rows + event_rows.reject { |row| debt_event_consumed_by_projection?(row, projected_account_ids) }
        cash_payment_credit = 0.to_d
        projection_adjustment = 0.to_d

        effect_rows.each do |row|
          debt_delta = row.fetch(:debt_delta, 0).to_d
          next if debt_delta.zero?

          account_id = debt_effect_account_id(row)
          if account_id.present? && debt_delta.negative? && remaining_gap_by_account.key?(account_id)
            credit = [ -debt_delta, remaining_gap_by_account.fetch(account_id) ].min
            remaining_gap_by_account[account_id] -= credit
            cash_payment_credit += credit
            projection_adjustment += debt_delta + credit
          else
            projection_adjustment += debt_delta
          end
        end

        {
          residual_cash_gap: remaining_gap_by_account.values.sum,
          cash_payment_credit: cash_payment_credit,
          projection_adjustment: projection_adjustment
        }
      end

      def debt_effect_account_id(row)
        row.fetch(:destination_account_id, nil) || row.fetch(:account_id, nil)
      end

      def debt_event_consumed_by_projection?(row, projected_account_ids)
        debt_owned_effect = row.fetch(:effect_type, nil).in?(%w[debt_drawdown debt_payment debt_interest]) ||
          row.fetch(:transaction_kind, nil).in?(%w[loan_payment debt_interest])
        return false unless debt_owned_effect

        projected_account_ids.include?(debt_effect_account_id(row))
      end

      # Minimum cash floor below which a month is considered cash-pressured. Defaults to
      # zero, but rises to the strictest minimum_cash_balance goal target so the same
      # floor that drives a goal blocker also drives the debt-pressure signal.
      def minimum_cash_floor
        targets = input.goals
          .select { |goal| goal["goal_type"] == "minimum_cash_balance" }
          .map { |goal| goal["target_amount"].to_d }

        targets.max || 0.to_d
      end

      # Pure arithmetic over month-local values: flag debt_pressures_runway only when the
      # unbudgeted debt cash gap is what drives this month's cash below the floor. If cash
      # was already below the floor without the gap, the debt payment is not the cause.
      def debt_pressure_risk_flags(cash:, cash_floor:, debt_payment_unbudgeted_cash_gap:, debt_projections:)
        return [] unless debt_payment_unbudgeted_cash_gap.positive?
        return [] unless cash < cash_floor
        return [] unless cash + debt_payment_unbudgeted_cash_gap >= cash_floor

        account_ids = debt_projections
          .filter_map { |row| row.fetch(:account_id, nil) }
          .uniq

        [
          {
            "type" => "debt_pressures_runway",
            "account_ids" => account_ids,
            "cash_floor" => cash_floor.to_s,
            "cash_balance" => cash.to_s,
            "debt_payment_unbudgeted_cash_gap" => debt_payment_unbudgeted_cash_gap.to_s
          }
        ]
      end

      def debt_to_cash_ratio_for(debt_balance, cash)
        return "0.0" if debt_balance.zero?
        return "infinite" if cash <= 0

        (debt_balance / cash).round(6).to_s
      end

      def actual_spending_already_reflected(category_projections, budget, period)
        first_day = input.periods.days.first
        return 0.to_d if first_day.blank? || period.start_date > first_day

        category_projections.sum { |row| row.fetch(:actual_spending).to_d } +
          budget.to_h.fetch(:actual_uncategorized_spending, 0).to_d
      end

      def budget_income_gap_for(budget, already_projected_income)
        return 0.to_d if budget.blank?

        expected_income = budget.fetch(:expected_income, 0).to_d
        actual_income = budget.fetch(:actual_income, 0).to_d
        [ expected_income - actual_income - already_projected_income, 0.to_d ].max
      end

      def runway_days(balance)
        monthly_spend = input.budgets.sum { |budget| monthly_budget_burn_for(budget) } / [ input.budgets.size, 1 ].max
        return nil if monthly_spend <= 0

        (balance / (monthly_spend / 30)).floor
      end

      def monthly_budget_burn_for(budget)
        budget.fetch(:categories).sum { |category| category.fetch(:budgeted_spending).to_d } +
          budget.to_h.fetch(:budgeted_uncategorized_spending, 0).to_d
      end

      def risk_flags_for(evaluations)
        evaluations.select { |evaluation| evaluation.status == "blocking" }.map do |evaluation|
          { "type" => "goal_blocker", "forecast_goal_id" => evaluation.forecast_goal_id }
        end
      end

      def feasibility_status_for(evaluations)
        return "blocked" if evaluations.any? { |evaluation| evaluation.status == "blocking" }
        return "warn" if evaluations.any? { |evaluation| evaluation.status.in?(%w[warn fail]) }

        "pass"
      end

      def input_risk_flags
        input.accounts.flat_map { |row| row.fetch(:risk_flags, []) } +
          input.budgets.flat_map { |budget| budget.fetch(:risk_flags, []) } +
          input.budgets.flat_map { |budget| budget.fetch(:categories).flat_map { |category| category.fetch(:risk_flags, []) } } +
          input.recurring_items.flat_map { |row| row.fetch(:risk_flags, []) } +
          input.pending_entries.flat_map { |row| row.fetch(:risk_flags, []) } +
          Array(input.portfolio.fetch(:risk_flags, [])) +
          input.events.flat_map { |row| row.fetch(:risk_flags, []) } +
          input.debt_rows.flat_map { |row| row.fetch(:risk_flags, []) }
      end
  end
end
