module Forecast
  class GoalEvaluator
    Evaluation = Data.define(:forecast_goal_id, :goal_key, :scenario_stack_key, :status, :currency, :metric_value, :target_value, :evaluated_on, :goal_snapshot, :details)

    def initialize(goals:, months:, scenario_stack_key:)
      @goals = goals
      @months = months
      @scenario_stack_key = scenario_stack_key
    end

    def call
      goals.map { |goal| evaluate(goal) }
    end

    private
      attr_reader :goals, :months, :scenario_stack_key

      def evaluate(goal)
        relevant_months = evaluation_months_for(goal)
        return unevaluated_goal(goal) if relevant_months.blank?

        case goal.fetch("goal_type")
        when "minimum_cash_runway"
          evaluate_runway(goal, relevant_months, :cash_runway_days)
        when "minimum_liquid_runway"
          evaluate_runway(goal, relevant_months, :liquid_runway_days)
        when "minimum_cash_balance"
          evaluate_amount(goal, relevant_months, :cash_balance)
        when "maximum_debt_balance"
          evaluate_maximum(goal, relevant_months, :debt_balance)
        else
          Evaluation.new(
            forecast_goal_id: goal.fetch("id"),
            goal_key: goal_key_for(goal),
            scenario_stack_key: scenario_stack_key,
            status: blocker_status(goal),
            currency: currency,
            metric_value: nil,
            target_value: nil,
            evaluated_on: relevant_months.last.period_end_on,
            goal_snapshot: goal,
            details: evaluation_window_details(goal, relevant_months).merge("reason" => "unsupported_goal_type", "goal_type" => goal.fetch("goal_type"))
          )
        end
      end

      def evaluate_runway(goal, relevant_months, field)
        target = goal.fetch("target_duration_days").to_d
        runway_values = relevant_months.filter_map { |month| month.public_send(field) }

        # A nil runway means the engine projected no spending in that month, so cash is
        # never exhausted (unbounded runway). If no evaluated month has a finite runway,
        # the goal is satisfied — coercing the absent minimum to 0 would falsely block it.
        if runway_values.empty?
          return Evaluation.new(
            forecast_goal_id: goal.fetch("id"),
            goal_key: goal_key_for(goal),
            scenario_stack_key: scenario_stack_key,
            status: "pass",
            currency: currency,
            metric_value: nil,
            target_value: target,
            evaluated_on: relevant_months.last.period_end_on,
            goal_snapshot: goal,
            details: evaluation_window_details(goal, relevant_months).merge("field" => field.to_s, "reason" => "runway_unbounded_no_spend")
          )
        end

        minimum = runway_values.min

        Evaluation.new(
          forecast_goal_id: goal.fetch("id"),
          goal_key: goal_key_for(goal),
          scenario_stack_key: scenario_stack_key,
          status: minimum >= target ? "pass" : blocker_status(goal),
          currency: currency,
          metric_value: minimum,
          target_value: target,
          evaluated_on: relevant_months.last.period_end_on,
          goal_snapshot: goal,
          details: evaluation_window_details(goal, relevant_months).merge("field" => field.to_s)
        )
      end

      def evaluate_amount(goal, relevant_months, field)
        target = goal.fetch("target_amount").to_d
        minimum = relevant_months.map { |month| month.public_send(field).to_d }.min

        Evaluation.new(
          forecast_goal_id: goal.fetch("id"),
          goal_key: goal_key_for(goal),
          scenario_stack_key: scenario_stack_key,
          status: minimum >= target ? "pass" : blocker_status(goal),
          currency: currency,
          metric_value: minimum,
          target_value: target,
          evaluated_on: relevant_months.last.period_end_on,
          goal_snapshot: goal,
          details: evaluation_window_details(goal, relevant_months).merge("field" => field.to_s)
        )
      end

      def evaluate_maximum(goal, relevant_months, field)
        target = goal.fetch("target_amount").to_d
        maximum = relevant_months.map { |month| month.public_send(field).to_d }.max

        Evaluation.new(
          forecast_goal_id: goal.fetch("id"),
          goal_key: goal_key_for(goal),
          scenario_stack_key: scenario_stack_key,
          status: maximum <= target ? "pass" : blocker_status(goal),
          currency: currency,
          metric_value: maximum,
          target_value: target,
          evaluated_on: relevant_months.last.period_end_on,
          goal_snapshot: goal,
          details: evaluation_window_details(goal, relevant_months).merge("field" => field.to_s)
        )
      end

      def unevaluated_goal(goal)
        Evaluation.new(
          forecast_goal_id: goal.fetch("id"),
          goal_key: goal_key_for(goal),
          scenario_stack_key: scenario_stack_key,
          status: "warn",
          currency: currency,
          metric_value: nil,
          target_value: goal["target_amount"] || goal["target_duration_days"],
          evaluated_on: nil,
          goal_snapshot: goal,
          details: evaluation_window_details(goal, []).merge("reason" => "goal_window_outside_forecast_horizon")
        )
      end

      def evaluation_months_for(goal)
        starts_on = parse_date(goal["evaluation_starts_on"] || goal["target_date"])
        ends_on = parse_date(goal["evaluation_ends_on"] || goal["target_date"])

        months.select do |month|
          after_start = starts_on.blank? || month.period_end_on >= starts_on
          before_end = ends_on.blank? || month.period_start_on <= ends_on
          after_start && before_end
        end
      end

      def evaluation_window_details(goal, relevant_months)
        {
          "evaluation_starts_on" => goal["evaluation_starts_on"],
          "evaluation_ends_on" => goal["evaluation_ends_on"],
          "evaluated_month_count" => relevant_months.length
        }
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return nil if value.blank?

        Date.parse(value.to_s)
      end

      def blocker_status(goal)
        goal.fetch("required") && goal.fetch("blocking_behavior").to_s.start_with?("blocks") ? "blocking" : "fail"
      end

      def goal_key_for(goal)
        "forecast_goal:#{goal.fetch("id")}"
      end

      def currency
        months.first&.currency
      end
  end
end
