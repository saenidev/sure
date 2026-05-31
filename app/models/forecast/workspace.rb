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
    TAB_IDS = %w[outlook what_if inputs reconcile history].freeze
    TAB_ALIASES = {
      "overview" => "outlook",
      "timeline" => "outlook",
      "comparison" => "what_if",
      "sensitivity" => "what_if",
      "scenarios" => "inputs",
      "goals" => "inputs",
      "templates" => "inputs",
      "reconciliation" => "reconcile",
      "review" => "history"
    }.freeze
    BASELINE_STACK_KEY = "baseline".freeze

    attr_reader :family

    def initialize(family:)
      @family = family
    end

    # The newest run group regardless of status, eager-loading only its runs and
    # goal evaluations. Month/projection rows are intentionally preloaded lazily
    # by the chart/timeline accessors that need them; the inputs/review routes
    # should not pay to load persisted projection output.
    def latest_group
      return @latest_group if defined?(@latest_group)

      @latest_group = family.forecast_run_groups
        .includes(forecast_runs: :forecast_goal_evaluations)
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

      preload_months_for(comparison_runs.presence || [ baseline_run ])
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
        .includes(:forecast_events, :forecast_budget_overrides, :forecast_budget_plan, :forecast_goals, :forecast_account_liquidity_settings)
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

    def active_scenarios_count
      scenario_groups.fetch("active", []).size
    end

    def planned_events_count
      @planned_events_count ||= family.forecast_events.where(status: "planned").count
    end

    def active_goals_count
      @active_goals_count ||= family.forecast_goals.where(status: "active").count
    end

    def active_budget_overrides_count
      @active_budget_overrides_count ||= family.forecast_budget_overrides.where(status: "active").count
    end

    def active_budget_plans_count
      @active_budget_plans_count ||= family.forecast_budget_plans.joins(:forecast_scenario).where(forecast_scenarios: { status: "active" }).count
    end

    def liquidity_settings_count
      @liquidity_settings_count ||= family.forecast_account_liquidity_settings.count
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
          effective_class: classifier.call(account, on: Date.current)
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
    # with baseline first then by stack key. Month rows are preloaded by the
    # comparison builders that need them so inputs-only routes stay light. Unlike
    # `baseline_run`, this surfaces runs even for a partially-failed group so the
    # comparison can show which stack failed alongside the ones that succeeded.
    def comparison_runs
      return @comparison_runs if defined?(@comparison_runs)
      return @comparison_runs = [] if latest_group.nil?

      # Reuse the runs already eager-loaded by `latest_group` and sort in Ruby,
      # avoiding an extra forecast_runs query.
      @comparison_runs = latest_group.forecast_runs.to_a
        .sort_by { |run| [ run.scenario_stack_key == BASELINE_STACK_KEY ? 0 : 1, run.scenario_stack_key.to_s ] }
    end

    # Read-only builder that turns the latest group's runs into one net-worth
    # series + end-of-horizon metrics per scenario stack. Reads persisted rows
    # only (no engine recompute). Returns nil when there is no run group yet.
    def comparison_series_builder
      return @comparison_series_builder if defined?(@comparison_series_builder)
      return @comparison_series_builder = nil if comparison_runs.empty?

      preload_months_for(comparison_runs)
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

    # --- Distribution bands & goal tradeoffs (read-only surfaces) -------------

    # Read-only builder that derives deterministic scenario bands (low/mid/high
    # per metric per common month) from the latest group's runs. Preloads the
    # month rows it needs in one batch and excludes failed stacks. Returns nil
    # when there is no run group to band yet, so the view can fall back to the
    # band empty state instead of constructing a builder over nothing.
    def distribution_band_builder
      return @distribution_band_builder if defined?(@distribution_band_builder)
      return @distribution_band_builder = nil if comparison_runs.empty?

      preload_months_for(comparison_runs)
      @distribution_band_builder = Forecast::DistributionBandBuilder.new(runs: comparison_runs)
    end

    # True only when there is more than one CONTRIBUTING (completed, populated)
    # stack to band: a single baseline-only group, an empty group, or a group
    # whose only non-baseline stack failed produces no meaningful band (a single
    # stack collapses low==mid==high), so the predicate is false and the view
    # shows the band empty state rather than a degenerate single-value band.
    def distribution_band_data?
      contributing_stack_count > 1 && (distribution_band_builder&.any? || false)
    end

    # Chart-ready deterministic bands (one MetricBands per banded metric, in
    # METRICS order) for the Comparison tab's band section. Returns [] when there
    # is nothing meaningful to band (see `distribution_band_data?`), so the view
    # falls back to the band empty state rather than a degenerate single-value
    # band. Reuses the builder's single persisted-row pass (no engine recompute).
    def distribution_metric_bands
      return [] unless distribution_band_data?

      distribution_band_builder.chart_bands.values
    end

    # Read-only explorer that ranks the latest group's scenario stacks by how many
    # goals they keep on-track and surfaces the tradeoffs each makes vs baseline.
    # Reuses the runs' `forecast_goal_evaluations` eager-loaded by `latest_group`
    # (no N+1 over runs x goals). Returns nil when there is no run group yet.
    def goal_tradeoff_explorer
      return @goal_tradeoff_explorer if defined?(@goal_tradeoff_explorer)
      return @goal_tradeoff_explorer = nil if comparison_runs.empty?

      @goal_tradeoff_explorer = Forecast::GoalTradeoffExplorer.new(runs: comparison_runs)
    end

    # True only when there is more than one CONTRIBUTING (completed) stack AND at
    # least one was actually ranked (i.e. goals were evaluated). A single-
    # baseline-only group, an empty group, or a group whose only non-baseline
    # stack failed has nothing to trade off, so the predicate is false and the
    # view shows the tradeoff empty state.
    def goal_tradeoff_data?
      contributing_stack_count > 1 && (goal_tradeoff_explorer&.any? || false)
    end

    # The ranked tradeoff rows for the Comparison tab's tradeoff table: one plain
    # Hash per contributing scenario stack, best-first (baseline as the reference,
    # any blocked stack pinned last). Returns [] when there is nothing to trade
    # off, so the view falls back to the tradeoff empty state. Reads the runs'
    # eager-loaded `forecast_goal_evaluations` only (no engine recompute, no N+1).
    def goal_tradeoff_rankings
      return [] unless goal_tradeoff_data?

      goal_tradeoff_explorer.explore
    end

    # The baseline stack key the tradeoff rows are compared against, so the view
    # can flag the reference row without re-deriving the constant.
    def baseline_stack_key
      Forecast::GoalTradeoffExplorer::BASELINE_STACK_KEY
    end

    # Map of engine goal_key ("forecast_goal:<id>") => human goal name, for the
    # tradeoff table to label each note/count by the goal's own name rather than
    # its opaque key. Scoped to THIS family's goals only (so another family's
    # goal name can never appear) and built in ONE query, so the table never
    # N+1s over notes x goals. A goal evaluated but since deleted falls back to
    # its key at the call site.
    def tradeoff_goal_labels
      return @tradeoff_goal_labels if defined?(@tradeoff_goal_labels)

      @tradeoff_goal_labels = family.forecast_goals.pluck(:id, :name).each_with_object({}) do |(id, name), memo|
        memo["forecast_goal:#{id}"] = name
      end
    end

    # Number of latest-group stacks that actually contribute to the band/tradeoff
    # surfaces: completed (not failed) runs only. A failed stack is excluded so a
    # group whose only non-baseline stack failed reads as a single contributing
    # stack (no real comparison). Reuses the eager-loaded comparison runs.
    def contributing_stack_count
      @contributing_stack_count ||= comparison_runs.count { |run| run.status == "completed" }
    end

    # Active scenarios the user can compose into stacks, ordered for the compose
    # form. Only active scenarios are projectable, mirroring the Runner's
    # ScenarioStack filter. Memoized; one query.
    def composable_scenarios
      @composable_scenarios ||= family.forecast_scenarios.active.ordered.to_a
    end

    # --- Sensitivity (deterministic single-variable analysis) -----------------

    # True when there is a completed baseline run to analyze, so the Sensitivity
    # tab/frame renders the perturbation rows rather than its empty state. The
    # analyzer re-runs the engine once per perturbation, so this only reads the
    # cheap baseline_run lookup; the heavy work is deferred to `sensitivity_rows`,
    # which the lazy Turbo Frame triggers (see Forecast::SensitivityController).
    def sensitivity_data?
      baseline_run.present?
    end

    # The deterministic single-variable sensitivity rows for the latest completed
    # baseline run. Builds ONE Forecast::InputBuilder result for the baseline
    # scenario stack (no scenarios) AT THE RUN'S OWN START DATE — never the wall
    # clock — then runs Forecast::SensitivityAnalyzer over the default
    # perturbation catalog. The result is deterministic for a fixed family state,
    # but the input is rebuilt from the LIVE family rather than the persisted run's
    # snapshot, so if accounts/budgets/recurring data changed since the run was
    # persisted the baseline (and deltas) re-derive a current-state baseline that
    # can diverge from the immutable run shown elsewhere on the page. The panel
    # surfaces that via `sensitivity_baseline_stale?` instead of presenting
    # silently.
    #
    # Memoized so the analyzer (which re-runs the engine N+1 times) executes at
    # most once per workspace instance. Returns [] when there is no completed
    # baseline run, so callers fall back to the empty state. The original input is
    # never mutated by the analyzer (each perturbation runs on a deep clone), and
    # the input is built fresh here — applying nothing to the persisted run rows.
    def sensitivity_rows
      return @sensitivity_rows if defined?(@sensitivity_rows)
      return @sensitivity_rows = [] unless sensitivity_data?

      input = Forecast::InputBuilder.new(
        family: family,
        user: sensitivity_user,
        scenario_ids: [],
        start_on: sensitivity_start_on
      ).call

      @sensitivity_rows = Forecast::SensitivityAnalyzer.new(input: input).call
    end

    # The metrics, in display order, each sensitivity row reports a delta for.
    # Centralized here so the view never re-derives the column set.
    SENSITIVITY_METRICS = %w[cash_balance net_worth debt_balance minimum_cash_runway_days].freeze

    def sensitivity_metrics
      SENSITIVITY_METRICS
    end

    # True when the recomputed sensitivity baseline diverges from the persisted
    # baseline run it claims to summarize. `sensitivity_rows` rebuilds a fresh
    # InputBuilder result from the live family (current accounts/budgets/recurring
    # data) at the run's own start date, so if that data changed since the run was
    # persisted the analyzer's baseline — and therefore every delta — describes a
    # different, re-derived baseline than the immutable run rendered everywhere
    # else on the page (Overview/Comparison/Timeline). When that happens the panel
    # surfaces an explicit staleness note rather than presenting silently.
    #
    # Compares the analyzer's unperturbed baseline (carried identically on every
    # row's `baseline_metric`) against the persisted baseline run's end-of-horizon
    # month. Reuses the already-loaded `monthly_rows` (no extra query) and the
    # memoized `sensitivity_rows`. False when there is nothing to compare.
    def sensitivity_baseline_stale?
      rows = sensitivity_rows
      return false if rows.empty?

      last_month = monthly_rows.last
      return false if last_month.nil?

      recomputed = rows.first.baseline_metric
      persisted = {
        "cash_balance" => last_month.cash_balance,
        "net_worth" => last_month.net_worth,
        "debt_balance" => last_month.debt_balance,
        # The analyzer's baseline runway is the worst (minimum) projected
        # cash_runway_days across the WHOLE horizon, not the last month — so the
        # persisted side must compute the same trough over every monthly row. A
        # live-data change that moves only the runway trough (leaving the
        # end-of-horizon balances identical) must still mark the panel stale.
        "minimum_cash_runway_days" => monthly_rows.filter_map(&:cash_runway_days).min
      }

      persisted.any? do |metric, persisted_value|
        if metric == "minimum_cash_runway_days"
          # Runway is nilable on both sides (nil == unbounded: no projected
          # spend). Both nil is equal; exactly one nil is a divergence; otherwise
          # compare the integer day counts.
          recomputed_runway = recomputed[metric]
          next false if persisted_value.nil? && recomputed_runway.nil?
          next true if persisted_value.nil? || recomputed_runway.nil?

          next recomputed_runway != persisted_value
        end

        next false if persisted_value.nil?

        recomputed[metric].to_d != persisted_value.to_d
      end
    end

    # Map of forecast_goal id => human goal name, so a sensitivity goal-status
    # change can be labeled by the goal's own name rather than its opaque id.
    # Scoped to THIS family's goals only (a foreign goal name can never appear)
    # and built in ONE query. A goal evaluated but since deleted falls back to its
    # id at the call site. Memoized.
    def sensitivity_goal_labels
      return @sensitivity_goal_labels if defined?(@sensitivity_goal_labels)

      @sensitivity_goal_labels = family.forecast_goals.pluck(:id, :name).to_h
    end

    # --- Timeline (single-run synchronized lanes) -----------------------------

    # The ForecastRun the Timeline tab renders. Reuses the baseline run of the
    # latest completed group (the headline projection). Nil when there is no
    # completed run, so the Timeline tab shows its empty state rather than another
    # family's run (the run is reached only through `latest_group`, which is
    # already scoped to this family).
    def timeline_run
      baseline_run
    end

    # Read-only model that assembles the six synchronized timeline lanes from the
    # timeline run's persisted output. Returns nil when there is no completed run.
    # Reads persisted rows only (no engine recompute).
    def timeline_read_model
      return @timeline_read_model if defined?(@timeline_read_model)
      return @timeline_read_model = nil unless timeline_run

      preload_timeline_projection_associations
      # Reuse the workspace's already-loaded daily/monthly rows plus the timeline
      # projection preload, so the Timeline tab adds no per-day/per-month or
      # per-projection queries.
      @timeline_read_model = Forecast::TimelineReadModel.new(
        timeline_run,
        days: daily_rows,
        months: monthly_rows
      )
    end

    # True when the Timeline tab has a completed run to render lanes for.
    def timeline_data?
      timeline_run.present?
    end

    # --- Reconciliation (expected-vs-actual linking) --------------------------

    # Read-only query for the Reconciliation tab: every event paired with its
    # derived lifecycle state (planned/due_soon/matched/missed) and accepted
    # link. The lifecycle is COMPUTED from dates + accepted links; it never
    # mutates ForecastEvent#status. Memoized so the tab and its summary share one
    # load.
    def reconciliation
      @reconciliation ||= Forecast::Reconciliation.new(family: family)
    end

    # True when the family has any events to reconcile.
    def reconciliation_data?
      !reconciliation.empty?
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

    def canonical_tab_id(tab_id)
      candidate = tab_id.to_s.presence || TAB_IDS.first
      TAB_ALIASES.fetch(candidate, candidate).presence_in(TAB_IDS) || TAB_IDS.first
    end

    # --- Review history --------------------------------------------------------

    # Past run groups for the Review tab's history list, newest first, paired
    # with their review (draft/awaiting/approved/...) status. Eager-loads the
    # review so the list adds no N+1 over each group, and scoped to this family.
    # Capped so the stub never renders an unbounded list.
    REVIEW_HISTORY_LIMIT = 25

    def review_history
      return @review_history if defined?(@review_history)

      @review_history = family.forecast_run_groups
        .includes(:forecast_review)
        .order(created_at: :desc)
        .limit(REVIEW_HISTORY_LIMIT)
        .to_a
    end

    def review_history?
      review_history.any?
    end

    # DS::Pill tone for a run-group status (history list badges).
    GROUP_STATUS_TONES = {
      "completed" => :indigo,
      "running" => :amber,
      "pending" => :gray,
      "failed" => :fuchsia
    }.freeze

    def group_status_tone(status)
      GROUP_STATUS_TONES.fetch(status, :gray)
    end

    private
      # The deterministic start date the sensitivity input is built at: the run
      # group's persisted horizon start, falling back to the baseline run's own
      # start snapshot, and only then to today. Threading the persisted run date
      # (never the live wall clock) keeps the analysis reproducible against the
      # run it summarizes — re-opening the tab tomorrow yields identical results.
      def sensitivity_start_on
        latest_group&.horizon_start_on ||
          baseline_run&.input_snapshot&.dig("periods", "start_on")&.then { |d| Date.parse(d) rescue nil } ||
          Date.current
      end

      # The user whose visibility/scope the sensitivity input is built under: the
      # baseline run's own user snapshot, falling back to the group's user. Both
      # are guaranteed to belong to this family by ForecastRun/ForecastRunGroup
      # validations, so the InputBuilder's IncludedAccountScope never leaks
      # another family's accounts.
      def sensitivity_user
        baseline_run&.user || latest_group&.user
      end

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

      def preload_months_for(runs)
        runs = Array(runs).compact
        return if runs.empty?

        unloaded_runs = runs.reject { |run| run.forecast_months.loaded? }
        return if unloaded_runs.empty?

        ActiveRecord::Associations::Preloader.new(
          records: unloaded_runs,
          associations: :forecast_months
        ).call
      end

      def preload_timeline_projection_associations
        return if @timeline_projection_associations_preloaded

        months = monthly_rows
        if months.any?
          ActiveRecord::Associations::Preloader.new(
            records: months,
            associations: [
              { forecast_category_projections: [ :category, :parent_category ] },
              { forecast_debt_projections: :account }
            ]
          ).call
        end

        @timeline_projection_associations_preloaded = true
      end
  end
end
