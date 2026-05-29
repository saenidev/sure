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
  #   :has_run    -> latest run group completed successfully
  #   :failed     -> latest run group failed (surfaces error_message)
  #
  # The "most recent wins" rule means a newer failed group supersedes an older
  # completed one, so users are never shown a stale success.
  class Workspace
    TAB_IDS = %w[overview timeline scenarios goals reconciliation review].freeze

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

    def error_message
      latest_group&.error_message if failed?
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
          # Pending/running (or otherwise non-terminal) latest group: treat it
          # like "ready to generate" so the user is never shown a stale state.
          :ready
        end
      end
  end
end
