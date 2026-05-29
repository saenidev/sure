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
    TAB_IDS = %w[overview timeline scenarios goals reconciliation review].freeze
    BASELINE_STACK_KEY = "baseline".freeze

    attr_reader :family

    def initialize(family:)
      @family = family
    end

    # The newest run group regardless of status, eager-loading its runs.
    def latest_group
      return @latest_group if defined?(@latest_group)

      @latest_group = family.forecast_run_groups
        .includes(:forecast_runs)
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
      @baseline_run = runs.find { |run| run.scenario_stack_key == BASELINE_STACK_KEY } || runs.first
    end

    # The 36 monthly projection rows for the baseline run, ordered for the
    # Overview table. Loaded once and memoized so the Overview's metrics row,
    # emptiness check, and table all share a single `forecast_months` query
    # (no N+1 over the 36 months).
    def monthly_rows
      return @monthly_rows if defined?(@monthly_rows)
      return @monthly_rows = [] unless baseline_run

      @monthly_rows = baseline_run.forecast_months.order(:period_start_on).to_a
    end

    # Whether the completed baseline run actually produced any projection rows.
    # Drives the Overview "no data yet" empty state (e.g. a family with zero
    # accounts/budgets still gets a run, just with nothing to chart).
    def overview_data?
      baseline_run.present? && monthly_rows.any?
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

    def events_count
      @events_count ||= family.forecast_events.count
    end

    def goals_count
      @goals_count ||= family.forecast_goals.count
    end

    def planning_data?
      scenarios_count.positive? || events_count.positive? || goals_count.positive?
    end

    # Number of scenario stacks the latest completed group projected.
    def scenario_stack_count
      return 0 unless has_run?

      latest_group.forecast_runs.size
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
      def compute_status
        group = latest_group

        if group.nil?
          planning_data? ? :ready : :onboarding
        elsif group.failed?
          :failed
        elsif group.completed?
          :has_run
        else
          # Pending/running (or otherwise non-terminal) latest group: a
          # generation is in flight, so surface the running state (and its
          # poller) rather than a stale success or a misleading "ready".
          :running
        end
      end
  end
end
