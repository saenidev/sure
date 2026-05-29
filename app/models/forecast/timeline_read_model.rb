module Forecast
  # Read-only PORO that assembles the unified timeline workspace for a SINGLE
  # completed ForecastRun (the run is obtained via Current.family scope by the
  # caller, never trusted from params).
  #
  # It reads ONLY the immutable output rows the Runner already persisted:
  #   * ForecastDay  (0-90 daily rows)               -> cash lane (daily resolution)
  #   * ForecastMonth (4-36 monthly rows) with        -> cash/budget/portfolio/debt
  #       forecast_category_projections and             lanes (monthly resolution)
  #       forecast_debt_projections preloaded
  #   * ForecastGoalEvaluation                        -> goals lane
  #   * the run's scenario_stack_snapshot             -> scenario lane
  #   * the run's input_snapshot["portfolio"]         -> portfolio holdings snapshot
  #
  # It NEVER touches Forecast::Engine / Forecast::InputBuilder or recomputes any
  # projection math — it only serializes persisted rows so the view can answer
  # "why is this number here?" from the stored source_breakdown JSON.
  #
  # Eager-loading: the constructor loads days, months (with their category/debt
  # projections), and goal evaluations in a bounded number of queries so the six
  # lanes render with no N+1 across 90 days + 36 months + per-month projections.
  class TimelineReadModel
    BASELINE_STACK_KEY = "baseline".freeze

    # Daily cash lane spans days 0-90; the monthly cash lane starts at the 4th
    # month (index 3) where daily precision hands off to monthly precision, so
    # the two resolutions do not overlap the same dates.
    MONTHLY_WINDOW_START_INDEX = 3

    DailyEntry = Data.define(:date, :cash_balance, :liquid_balance, :net_worth, :debt_balance, :cash_runway_days, :liquid_runway_days, :source_breakdown, :risk_flags)
    MonthEntry = Data.define(:period_start_on, :period_end_on, :expected_income, :expected_spending, :net_cash_flow, :cash_balance, :liquid_balance, :portfolio_value, :debt_balance, :net_worth, :cash_runway_days, :source_breakdown, :risk_flags, :category_projections, :debt_projections)
    BudgetRow = Data.define(:label, :source, :budgeted, :projected, :available, :source_breakdown)
    PortfolioHolding = Data.define(:ticker, :qty, :amount)
    DebtRow = Data.define(:label, :opening_balance, :projected_interest, :projected_payment, :projected_drawdown, :ending_balance, :cash_payment_gap, :source, :source_breakdown)
    GoalRow = Data.define(:label, :status, :metric_value, :target_value, :currency, :evaluated_on)
    ScenarioRow = Data.define(:name, :starts_on, :ends_on, :approval_status)

    # `days` / `months` / `goal_evaluations` may be passed in already loaded (e.g.
    # by the Workspace, which shares one eager-load across the Overview and the
    # Timeline tabs) so this model issues no further per-row queries. The months
    # MUST be loaded with `forecast_category_projections` and
    # `forecast_debt_projections` preloaded for the budget/debt lanes to avoid
    # N+1. When nothing is passed (e.g. a unit test), they are loaded here.
    def initialize(run, days: nil, months: nil, goal_evaluations: nil)
      @run = run
      @days = days
      @months = months
      @goal_evaluations = goal_evaluations
    end

    attr_reader :run

    def currency
      run.currency
    end

    # --- shared loaded collections (eager-loaded, memoized) --------------------

    # 90 ForecastDay rows ordered chronologically. One query when not pre-loaded.
    def days
      @days ||= run.forecast_days.order(:date).to_a
    end

    # 36 ForecastMonth rows ordered chronologically, with their category and debt
    # projections preloaded so the budget/debt lanes never N+1 per month. When
    # not pre-loaded, this issues one query per association regardless of month
    # count.
    def months
      @months ||= run.forecast_months
        .includes(
          { forecast_category_projections: [ :category, :parent_category ] },
          { forecast_debt_projections: :account }
        )
        .order(:period_start_on)
        .to_a
    end

    # ForecastGoalEvaluation rows for this run, with the optional goal preloaded
    # so the goals lane can label each row without a per-goal query. One query
    # when not pre-loaded.
    def goal_evaluations
      @goal_evaluations ||= run.forecast_goal_evaluations.includes(:forecast_goal).to_a
    end

    # --- resolution-aware lane entries ----------------------------------------

    # Daily cash-lane entries (0-90). Drives the daily-resolution view.
    def daily_entries
      @daily_entries ||= days.map do |day|
        DailyEntry.new(
          date: day.date,
          cash_balance: money(day.cash_balance),
          liquid_balance: money(day.liquid_balance),
          net_worth: money(day.net_worth),
          debt_balance: money(day.debt_balance),
          cash_runway_days: day.cash_runway_days,
          liquid_runway_days: day.liquid_runway_days,
          source_breakdown: day.source_breakdown || {},
          risk_flags: risk_flag_types(day.risk_flags)
        )
      end
    end

    # Monthly entries for the 4-36 window (months after the daily hand-off).
    # Drives the monthly-resolution view across every lane.
    def monthly_entries
      @monthly_entries ||= windowed_months.map { |month| month_entry(month) }
    end

    # All 36 monthly entries (used by lanes that span the whole horizon, e.g. the
    # budget/portfolio/debt lanes which are monthly-only regardless of toggle).
    def all_monthly_entries
      @all_monthly_entries ||= months.map { |month| month_entry(month) }
    end

    # --- lanes -----------------------------------------------------------------

    # cash lane: daily 0-90 cash balances + monthly fallback, plus a sparkline.
    def cash_series
      Forecast::SeriesBuilder.new(run, days: days, months: months).cash_runway_series
    end

    # portfolio lane: monthly portfolio_value series + the holdings snapshot.
    def portfolio_series
      Forecast::SeriesBuilder.new(run, days: days, months: months).net_worth_series
    end

    # The holdings captured in the run's input snapshot (read-only). Lets the
    # portfolio lane show the composition behind the projected portfolio value
    # without recomputing anything.
    def portfolio_holdings
      raw = run.input_snapshot.is_a?(Hash) ? run.input_snapshot.dig("portfolio", "holdings") : nil
      Array(raw).filter_map do |holding|
        next unless holding.is_a?(Hash)

        PortfolioHolding.new(
          ticker: holding["ticker"].presence || holding["security_id"],
          qty: holding["qty"].to_d,
          amount: money(holding["amount"].to_d)
        )
      end
    end

    def portfolio_holdings?
      portfolio_holdings.any?
    end

    # budget lane: the category projection rows for a given month entry, mapped
    # to display rows. Reads the preloaded association (no query).
    def budget_rows_for(month_entry)
      month_entry.category_projections.map do |projection|
        BudgetRow.new(
          label: category_label(projection),
          source: projection.source,
          budgeted: money(projection.budgeted_spending),
          projected: money(projection.projected_spending),
          available: money(projection.available_to_spend),
          source_breakdown: projection.source_breakdown || {}
        )
      end
    end

    # debt lane: the debt projection rows for a given month entry, mapped to
    # display rows (opening/interest/payment/drawdown/ending). No query.
    def debt_rows_for(month_entry)
      month_entry.debt_projections.map do |projection|
        DebtRow.new(
          label: debt_label(projection),
          opening_balance: money(projection.opening_balance),
          projected_interest: money(projection.projected_interest),
          projected_payment: money(projection.projected_payment),
          projected_drawdown: money(projection.projected_drawdown),
          ending_balance: money(projection.ending_balance),
          cash_payment_gap: money(projection.cash_payment_gap),
          source: projection.source,
          source_breakdown: projection.source_breakdown || {}
        )
      end
    end

    # True when ANY month carries at least one debt projection. Drives the debt
    # lane empty state (a run with no debt renders an empty-state, not a crash).
    def debt_projections?
      all_monthly_entries.any? { |month| month.debt_projections.any? }
    end

    # goals lane: one row per goal evaluation, labelled and statused.
    def goals_lane
      @goals_lane ||= goal_evaluations.map do |evaluation|
        GoalRow.new(
          label: goal_label(evaluation),
          status: evaluation.status,
          metric_value: evaluation.metric_value && money(evaluation.metric_value, evaluation.currency),
          target_value: evaluation.target_value && money(evaluation.target_value, evaluation.currency),
          currency: evaluation.currency,
          evaluated_on: evaluation.evaluated_on
        )
      end
    end

    def goals?
      goals_lane.any?
    end

    # scenario lane: the active scenarios that contributed to this run, read from
    # the scenario_stack_snapshot. A baseline run (no scenarios) yields [], so the
    # view shows just the "baseline" marker.
    def scenario_lane
      @scenario_lane ||= begin
        scenarios = run.scenario_stack_snapshot.is_a?(Hash) ? Array(run.scenario_stack_snapshot["scenarios"]) : []
        scenarios.filter_map do |scenario|
          next unless scenario.is_a?(Hash)

          ScenarioRow.new(
            name: scenario["name"],
            starts_on: parse_date(scenario["starts_on"]),
            ends_on: parse_date(scenario["ends_on"]),
            approval_status: scenario["approval_status"]
          )
        end
      end
    end

    # True when this run is the baseline stack (no active scenarios contributed).
    def baseline?
      run.scenario_stack_key == BASELINE_STACK_KEY || scenario_lane.empty?
    end

    # --- drilldown -------------------------------------------------------------

    # Humanizes a persisted source_breakdown hash into ordered label/value rows
    # so the drilldown can answer "why is this number here?". Numeric-looking
    # values are wrapped as Money in the run currency; everything else is shown
    # as-is. Keys are humanized via i18n with a sensible fallback.
    DrilldownRow = Data.define(:key, :label, :value, :money)

    def drilldown_rows(source_breakdown)
      return [] unless source_breakdown.is_a?(Hash)

      source_breakdown.filter_map do |key, value|
        next if value.nil? || value == ""

        is_money = money_like?(value)
        DrilldownRow.new(
          key: key.to_s,
          label: I18n.t("forecasts.timeline.drilldown.keys.#{key}", default: key.to_s.humanize),
          value: value,
          money: is_money ? money(value.to_d) : nil
        )
      end
    end

    private
      def windowed_months
        months[MONTHLY_WINDOW_START_INDEX..] || []
      end

      def month_entry(month)
        MonthEntry.new(
          period_start_on: month.period_start_on,
          period_end_on: month.period_end_on,
          expected_income: money(month.expected_income),
          expected_spending: money(month.expected_spending),
          net_cash_flow: money(month.net_cash_flow),
          cash_balance: money(month.cash_balance),
          liquid_balance: money(month.liquid_balance),
          portfolio_value: money(month.portfolio_value),
          debt_balance: money(month.debt_balance),
          net_worth: money(month.net_worth),
          cash_runway_days: month.cash_runway_days,
          source_breakdown: month.source_breakdown || {},
          risk_flags: risk_flag_types(month.risk_flags),
          # Sort the preloaded associations in Ruby so reading them never issues a
          # query (calling .order on a loaded association would re-query -> N+1).
          category_projections: month.forecast_category_projections.to_a.sort_by { |row| row.projection_key.to_s },
          debt_projections: month.forecast_debt_projections.to_a.sort_by { |row| row.projection_key.to_s }
        )
      end

      def money(amount, override_currency = nil)
        Money.new(amount, override_currency || currency)
      end

      def money_like?(value)
        return true if value.is_a?(Numeric)
        return false unless value.is_a?(String)

        value.match?(/\A-?\d+(\.\d+)?\z/)
      end

      def risk_flag_types(flags)
        Array(flags).map { |flag| flag.is_a?(Hash) ? (flag["type"] || flag[:type]) : flag }
          .compact_blank
          .uniq
          .map(&:to_s)
      end

      def category_label(projection)
        projection.category&.name.presence ||
          projection.parent_category&.name.presence ||
          I18n.t("forecasts.timeline.budget_lane.uncategorized")
      end

      def debt_label(projection)
        projection.account&.name.presence ||
          projection.projection_key.presence ||
          I18n.t("forecasts.timeline.debt_lane.unnamed")
      end

      def goal_label(evaluation)
        evaluation.forecast_goal&.name.presence ||
          evaluation.goal_snapshot&.dig("name").presence ||
          evaluation.goal_key.to_s
      end

      def parse_date(value)
        return nil if value.blank?

        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
