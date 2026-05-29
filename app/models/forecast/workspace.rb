module Forecast
  # Query object that decides which state the forecast workspace should render.
  #
  # It loads the family's most recent forecast run group (eager-loading its
  # runs) and the counts of planning objects (scenarios/events/goals) so the
  # controller can pick one of four states without leaking query logic into the
  # view:
  #
  #   :onboarding -> no planning data and no run group yet
  #   :ready      -> planning data exists but no completed run group yet
  #   :running    -> latest run group is pending/running (generation in flight)
  #   :has_run    -> latest run group completed successfully
  #   :failed     -> latest run group failed (surfaces error_message)
  #
  # The "most recent wins" rule means a newer failed group supersedes an older
  # completed one, so users are never shown a stale success.
  class Workspace
    TAB_IDS = %w[overview comparison timeline scenarios goals reconciliation review].freeze
    BASELINE_STACK_KEY = "baseline".freeze

    attr_reader :family

    def initialize(family:)
      @family = family
    end

    # The newest run group regardless of status, eager-loading its runs and the
    # runs' monthly projection rows in one batched query. Both the Overview
    # (baseline run's months) and the Comparison tab (every run's months) read
    # from this single preload, so the workspace never N+1s over runs x months.
    def latest_group
      return @latest_group if defined?(@latest_group)

      @latest_group = family.forecast_run_groups
        .includes(forecast_runs: :forecast_months)
        .order(created_at: :desc)
        .first
    end

    def status
      @status ||= compute_status
    end

    def onboarding?
      status == :onboarding
    end

    def ready?
      status == :ready
    end

    # True when a generation is in flight (latest group pending or running).
    # The model layer owns this so the controller/view never re-derive the rule.
    def running?
      status == :running
    end

    def has_run?
      status == :has_run
    end

    def failed?
      status == :failed
    end

    # The run group to summarize when one completed successfully.
    def run_group
      latest_group if has_run?
    end

    # The in-flight run group (pending/running) the poller watches.
    def running_group
      latest_group if running?
    end

    def error_message
      latest_group&.error_message if failed?
    end

    # The baseline ForecastRun (empty scenario stack) of the latest completed
    # group, which the Overview tab summarizes. Falls back to the first run when
    # no baseline key is present so the Overview is never blank for a completed
    # group. Runs are eager-loaded with the group, so this adds no queries.
    def baseline_run
      return @baseline_run if defined?(@baseline_run)
      return @baseline_run = nil unless has_run?

      runs = latest_group.forecast_runs.to_a
      # Prefer the completed baseline stack; in a partial-failure group the
      # baseline stack itself may have failed, so fall back to any completed run
      # (then any run) so the Overview headline summarizes real output.
      @baseline_run =
        runs.find { |run| run.scenario_stack_key == BASELINE_STACK_KEY && run.status == "completed" } ||
        runs.find { |run| run.status == "completed" } ||
        runs.find { |run| run.scenario_stack_key == BASELINE_STACK_KEY } ||
        runs.first
    end

    # The 36 monthly projection rows for the baseline run, ordered for the
    # Overview table. Loaded once and memoized so the Overview's metrics row,
    # emptiness check, and table all share a single `forecast_months` query
    # (no N+1 over the 36 months).
    def monthly_rows
      return @monthly_rows if defined?(@monthly_rows)
      return @monthly_rows = [] unless baseline_run

      # Sort the eager-loaded association in Ruby; calling `.order` on a loaded
      # association would issue a second forecast_months query (N+1).
      @monthly_rows = baseline_run.forecast_months.to_a.sort_by(&:period_start_on)
    end

    # The 90 daily projection rows for the baseline run, ordered for the
    # cash-runway chart. Loaded once and memoized so the runway chart and its
    # risk annotation share a single `forecast_days` query (no N+1 over 90 days).
    def daily_rows
      return @daily_rows if defined?(@daily_rows)
      return @daily_rows = [] unless baseline_run

      @daily_rows = baseline_run.forecast_days.order(:date).to_a
    end

    # Whether the completed baseline run actually produced any projection rows.
    # Drives the Overview "no data yet" empty state (e.g. a family with zero
    # accounts/budgets still gets a run, just with nothing to chart).
    def overview_data?
      baseline_run.present? && monthly_rows.any?
    end

    # Read-only builder that serializes the baseline run's persisted day/month
    # rows into Series-shaped chart data. Reuses the already-loaded daily/monthly
    # arrays so the charts add no queries beyond the two list loads. Returns nil
    # when there is no baseline run to chart.
    def series_builder
      return @series_builder if defined?(@series_builder)
      return @series_builder = nil unless baseline_run

      @series_builder = Forecast::SeriesBuilder.new(
        baseline_run,
        days: daily_rows,
        months: monthly_rows
      )
    end

    # Currency the baseline run/group was projected in (for Money formatting).
    def currency
      baseline_run&.currency || latest_group&.currency || family.currency
    end

    # The DS::Pill tone for the baseline run's feasibility status. Maps the
    # engine's pass/warn/blocked/unknown to design-system color ramps.
    def feasibility_status
      baseline_run&.feasibility_status || "unknown"
    end

    FEASIBILITY_TONES = {
      "pass" => :indigo,
      "warn" => :amber,
      "blocked" => :fuchsia,
      "unknown" => :gray
    }.freeze

    def feasibility_tone
      FEASIBILITY_TONES.fetch(feasibility_status, :gray)
    end

    # Distinct risk-flag "type" keys raised across the latest completed group,
    # normalized to strings the view humanizes via i18n. Flags are stored either
    # as hashes ({"type" => "stale_fx_rate", ...}) or bare strings; we collapse
    # both to their type token so the Overview lists each kind once.
    def risk_flag_types
      return [] unless has_run?

      Array(latest_group.risk_flags).map { |flag| flag.is_a?(Hash) ? flag["type"] : flag }
        .compact_blank
        .uniq
    end

    def scenarios_count
      @scenarios_count ||= family.forecast_scenarios.count
    end

    # Family scenarios grouped by status for the Scenarios tab. Eager-loads the
    # planning children so the row badges/counts add no N+1 over each scenario.
    # Memoized so re-rendering the tab does not re-query.
    def scenario_groups
      return @scenario_groups if defined?(@scenario_groups)

      scenarios = family.forecast_scenarios
        .includes(:forecast_events, :forecast_budget_overrides, :forecast_goals, :forecast_account_liquidity_settings)
        .ordered
        .to_a

      @scenario_groups = {
        "active" => scenarios.select(&:active?),
        "disabled" => scenarios.select(&:disabled?),
        "archived" => scenarios.select(&:archived?)
      }
    end

    def events_count
      @events_count ||= family.forecast_events.count
    end

    def goals_count
      @goals_count ||= family.forecast_goals.count
    end

    # Goals for the Goals tab, each paired with the status of its most recent
    # evaluation from the latest completed run group. Eager-loads the optional
    # scenario so the row badge/scope label adds no N+1. The evaluation lookup is
    # a single query over the group's runs (joined by the engine's `goal_key`,
    # which is "forecast_goal:<id>"); goals without a matching eval (no run yet,
    # or evaluated outside the horizon) surface as "unknown". Memoized.
    def goals_with_evaluations
      return @goals_with_evaluations if defined?(@goals_with_evaluations)

      goals = family.forecast_goals
        .includes(:forecast_scenario)
        .order(Arel.sql("CASE status WHEN 'active' THEN 0 WHEN 'disabled' THEN 1 ELSE 2 END"), created_at: :asc)
        .to_a

      statuses = latest_evaluation_statuses

      @goals_with_evaluations = goals.map do |goal|
        [ goal, statuses["forecast_goal:#{goal.id}"] ]
      end
    end

    # Per-account liquidity rows for the settings sub-panel: each visible family
    # account paired with its baseline override setting (if any) and its
    # default/effective classification. Eager-loads accountable so the classifier
    # does not N+1 over account types, and loads all baseline settings in one
    # query keyed by account.
    def liquidity_rows
      return @liquidity_rows if defined?(@liquidity_rows)

      accounts = family.accounts.visible.includes(:accountable).alphabetically.to_a
      settings_by_account = family.forecast_account_liquidity_settings
        .where(forecast_scenario_id: nil)
        .index_by(&:account_id)
      classifier = Forecast::LiquidityClassifier.new(family: family, scenario_ids: [])

      @liquidity_rows = accounts.map do |account|
        {
          account: account,
          setting: settings_by_account[account.id],
          effective_class: classifier.call(account)
        }
      end
    end

    def planning_data?
      scenarios_count.positive? || events_count.positive? || goals_count.positive?
    end

    # Number of scenario stacks the latest completed group projected.
    def scenario_stack_count
      return 0 unless has_run?

      latest_group.forecast_runs.size
    end

    # --- Comparison (scenario-stack) accessors --------------------------------

    # The runs of the latest group (regardless of group status), ordered stably
    # with baseline first then by stack key, with their months eager-loaded so
    # the comparison table/chart never N+1 over runs x 36 months. Unlike
    # `baseline_run`, this surfaces runs even for a partially-failed group so the
    # comparison can show which stack failed alongside the ones that succeeded.
    def comparison_runs
      return @comparison_runs if defined?(@comparison_runs)
      return @comparison_runs = [] if latest_group.nil?

      # Reuse the runs (and their months) already eager-loaded by `latest_group`
      # and sort in Ruby — no extra forecast_runs / forecast_months query.
      @comparison_runs = latest_group.forecast_runs.to_a
        .sort_by { |run| [ run.scenario_stack_key == BASELINE_STACK_KEY ? 0 : 1, run.scenario_stack_key.to_s ] }
    end

    # Read-only builder that turns the latest group's runs into one net-worth
    # series + end-of-horizon metrics per scenario stack. Reads persisted rows
    # only (no engine recompute). Returns nil when there is no run group yet.
    def comparison_series_builder
      return @comparison_series_builder if defined?(@comparison_series_builder)
      return @comparison_series_builder = nil if comparison_runs.empty?

      @comparison_series_builder = Forecast::ComparisonSeriesBuilder.new(runs: comparison_runs)
    end

    # The per-stack comparison rows for the comparison table/chart, or [] when
    # there is nothing to compare yet.
    def comparison_stacks
      comparison_series_builder&.stacks || []
    end

    # True when the latest group has at least one run to compare.
    def comparison_data?
      comparison_runs.any?
    end

    # True when the latest group has more than the baseline stack — i.e. an
    # actual comparison (not just a single baseline run).
    def multiple_stacks?
      comparison_runs.size > 1
    end

    # True when any stack in the latest comparison group failed, so the view can
    # surface the partial-failure banner without dropping completed stacks.
    def comparison_partial_failure?
      comparison_runs.any? { |run| run.status == "failed" }
    end

    # The DS::Pill tone for a run-level feasibility status (reuses the same ramp
    # as the baseline overview). A failed run maps to the blocked/fuchsia tone.
    def feasibility_tone_for(status)
      FEASIBILITY_TONES.fetch(status, :gray)
    end

    # Active scenarios the user can compose into stacks, ordered for the compose
    # form. Only active scenarios are projectable, mirroring the Runner's
    # ScenarioStack filter. Memoized; one query.
    def composable_scenarios
      @composable_scenarios ||= family.forecast_scenarios.active.ordered.to_a
    end

    def generated_at
      latest_group&.finished_at || latest_group&.created_at if has_run?
    end

    def horizon_start_on
      latest_group&.horizon_start_on if has_run?
    end

    def horizon_end_on
      latest_group&.horizon_end_on if has_run?
    end

    def tab_ids
      TAB_IDS
    end

    private
      # Map of goal_key -> status string from the latest completed run group.
      # Prefers the baseline run's evaluation (the headline projection) and falls
      # back to any run's evaluation for that key. Returns {} when no completed
      # run exists, so every goal renders the "unknown" empty state. One query.
      def latest_evaluation_statuses
        return {} unless has_run? && baseline_run

        evaluations = ForecastGoalEvaluation
          .where(forecast_run_id: latest_group.forecast_runs.map(&:id))
          .pluck(:goal_key, :forecast_run_id, :status)

        baseline_id = baseline_run.id
        evaluations.each_with_object({}) do |(goal_key, run_id, status), memo|
          memo[goal_key] = status if run_id == baseline_id || !memo.key?(goal_key)
        end
      end

      def compute_status
        group = latest_group

        if group.nil?
          planning_data? ? :ready : :onboarding
        elsif group.failed?
          # A failed *comparison* group can still carry completed stacks (only
          # some scenario stacks errored). In that partial-failure case we show
          # the workspace + results (with a per-stack failure surface in the
          # Comparison tab) rather than a blank failure page. Only a group with
          # no completed run at all is a true, total failure.
          group_has_completed_run? ? :has_run : :failed
        elsif group.completed?
          :has_run
        else
          # Pending/running (or otherwise non-terminal) latest group: a
          # generation is in flight, so surface the running state (and its
          # poller) rather than a stale success or a misleading "ready".
          :running
        end
      end

      def group_has_completed_run?
        latest_group.forecast_runs.any? { |run| run.status == "completed" }
      end
  end
end
