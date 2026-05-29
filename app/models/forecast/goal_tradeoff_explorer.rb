module Forecast
  # Read-only PORO that answers the Phase-10 acceptance question — "which changes
  # best preserve my goals?" — over the already-computed ForecastRun rows of ONE
  # comparison ForecastRunGroup. Each completed run carries its immutable
  # `forecast_goal_evaluations` (one per goal it was graded against). This explorer
  # ranks the scenario stacks by how many goals they keep on-track and surfaces the
  # explicit tradeoffs each stack makes relative to the baseline stack.
  #
  # IMPORTANT: there is NO new engine math here, NO optimization solver, and NO
  # RNG. It reads the persisted, trusted goal evaluations and ranks them
  # deterministically with stable tie-breaks. The SAME persisted rows always
  # produce the SAME ranking. Like the other read-model builders it NEVER touches
  # `Forecast::Engine`; callers SHOULD pass runs with `forecast_goal_evaluations`
  # eager-loaded to avoid N+1.
  #
  # Goal classification (per stack):
  #   * satisfied — the goal evaluation status is "pass".
  #   * blocked   — the goal evaluation status is "blocking" (a required goal that
  #     failed in a way that blocks the scenario/stack). A blocked goal is the
  #     strongest signal and forces the stack to the bottom of the ranking.
  #   * at_risk   — anything else: "warn", "fail", an "unknown"/missing evaluation,
  #     or a goal the stack did not evaluate at all. These are NOT counted as
  #     satisfied — an unknown/warn goal must never read as on-track.
  #
  # Ranking is deterministic with stable tie-breaks, in order:
  #   1. has-any-blocked-goal, ascending (clean stacks rank above ANY blocked
  #      stack — a blocking goal sinks the stack "regardless of other satisfied
  #      goals", which is the Phase-10 acceptance rule).
  #   2. satisfied goal count, descending (more goals kept on-track ranks first)
  #   3. blocked goal count, ascending (fewer blocked among blocked stacks first)
  #   4. scenario stack key, ascending (final deterministic tie-break)
  # A stack that satisfies every goal ranks first; a stack with any blocked goal
  # ranks last regardless of how many other goals it satisfies.
  #
  # Tradeoffs are read straight from the immutable goal evaluations: for each goal
  # shared with the baseline stack we compare the stack's `metric_value` to the
  # baseline's, classifying the delta as an improvement or a regression in the
  # goal's own direction (more is better for runway/balance goals, less is better
  # for maximum-debt goals). The notes therefore explain, e.g., "+2 months of
  # runway on goal X alongside a higher projected debt balance on goal Y" using
  # only trusted persisted numbers.
  class GoalTradeoffExplorer
    BASELINE_STACK_KEY = "baseline".freeze

    SATISFIED_STATUS = "pass".freeze
    BLOCKED_STATUS = "blocking".freeze

    # Goal types where a SMALLER metric value is the better outcome. For these a
    # decrease vs baseline is an improvement; for every other goal type a larger
    # value is the improvement. Used only to label tradeoff direction — never to
    # recompute the evaluation itself.
    LOWER_IS_BETTER_GOAL_TYPES = %w[maximum_debt_balance].freeze

    # One ranked scenario stack with its goal classification and the tradeoffs it
    # makes relative to baseline. `tradeoff_notes` is an ordered array of structured
    # hashes (machine-readable, deterministic) the UI formats for display.
    StackRanking = Data.define(
      :stack_key,
      :label,
      :satisfied_goal_keys,
      :at_risk_goal_keys,
      :blocked_goal_keys,
      :tradeoff_notes
    )

    # One marginal-metric delta on one goal vs the baseline stack.
    TradeoffNote = Data.define(
      :goal_key,
      :goal_type,
      :direction,          # "improvement" | "regression" | "unchanged"
      :baseline_metric_value,
      :stack_metric_value,
      :metric_delta,       # signed change in raw metric units (stack - baseline)
      :currency,
      :field               # the underlying engine field measured, e.g. "cash_runway_days"
    )

    # `runs` is the ForecastRun collection of one group, ideally with
    # `forecast_goal_evaluations` eager-loaded. `goal_keys` optionally restricts the
    # ranking to a subset of goals; when omitted, every goal key evaluated across
    # the contributing stacks is considered (sorted for determinism).
    def initialize(runs:, goal_keys: nil)
      @runs = Array(runs)
      @requested_goal_keys = goal_keys&.map(&:to_s)
    end

    # Ordered array of plain Hashes: one per contributing scenario stack, ranked
    # best-first. Each hash carries stack_key, label, satisfied/at_risk/blocked goal
    # key arrays, and tradeoff_notes. Returns [] for an empty group or one with no
    # contributing (completed, evaluated) stacks.
    def explore
      rankings.map do |ranking|
        {
          stack_key: ranking.stack_key,
          label: ranking.label,
          satisfied_goal_keys: ranking.satisfied_goal_keys,
          at_risk_goal_keys: ranking.at_risk_goal_keys,
          blocked_goal_keys: ranking.blocked_goal_keys,
          tradeoff_notes: ranking.tradeoff_notes.map(&:to_h)
        }
      end
    end

    # The ranked StackRanking structs (best-first). Memoized so repeated reads share
    # a single pass over the persisted rows.
    def rankings
      @rankings ||= build_rankings
    end

    # True when at least one contributing stack was ranked.
    def any?
      rankings.any?
    end

    private
      attr_reader :runs, :requested_goal_keys

      # Completed (not failed) runs only — a failed stack is excluded from the
      # ranking so it cannot masquerade as a stack that satisfies (or blocks) goals.
      # Ordered by stack key for a stable downstream pass.
      def contributing_runs
        @contributing_runs ||= runs
          .reject { |run| run.status == "failed" }
          .sort_by { |run| run.scenario_stack_key.to_s }
      end

      # The set of goal keys we rank against: the requested subset if given,
      # otherwise every goal key evaluated across the contributing stacks. Sorted so
      # the considered universe is deterministic regardless of DB row order.
      def goal_keys
        @goal_keys ||= begin
          evaluated = contributing_runs.flat_map { |run| evaluations_for(run).map(&:goal_key) }.uniq
          (requested_goal_keys || evaluated).uniq.sort
        end
      end

      def build_rankings
        return [] if contributing_runs.empty? || goal_keys.empty?

        baseline = baseline_evaluations_by_goal_key

        ranked = contributing_runs.map { |run| classify(run, baseline) }

        ranked.sort_by do |ranking|
          [
            ranking.blocked_goal_keys.empty? ? 0 : 1, # clean stacks above ANY blocked stack
            -ranking.satisfied_goal_keys.size,         # more satisfied first
            ranking.blocked_goal_keys.size,            # fewer blocked first (among blocked)
            ranking.stack_key.to_s                     # stable final tie-break
          ]
        end
      end

      # Classify each considered goal for one stack into satisfied / at_risk /
      # blocked, and compute its tradeoff notes vs baseline. Goal key arrays are
      # sorted for deterministic output.
      def classify(run, baseline)
        evaluations = evaluations_by_goal_key(run)

        satisfied = []
        at_risk = []
        blocked = []

        goal_keys.each do |goal_key|
          case status_for(evaluations[goal_key])
          when SATISFIED_STATUS then satisfied << goal_key
          when BLOCKED_STATUS   then blocked << goal_key
          else                       at_risk << goal_key
          end
        end

        StackRanking.new(
          stack_key: run.scenario_stack_key,
          label: label_for(run),
          satisfied_goal_keys: satisfied.sort,
          at_risk_goal_keys: at_risk.sort,
          blocked_goal_keys: blocked.sort,
          tradeoff_notes: tradeoff_notes(run, evaluations, baseline)
        )
      end

      # Marginal metric deltas vs baseline for every considered goal both the stack
      # and baseline evaluated with a finite metric. The baseline stack itself has no
      # tradeoffs (it is the reference). Ordered by goal key for determinism.
      def tradeoff_notes(run, evaluations, baseline)
        return [] if run.scenario_stack_key == BASELINE_STACK_KEY

        goal_keys.filter_map do |goal_key|
          stack_eval = evaluations[goal_key]
          base_eval = baseline[goal_key]
          next if stack_eval.nil? || base_eval.nil?

          stack_value = stack_eval.metric_value
          base_value = base_eval.metric_value
          next if stack_value.nil? || base_value.nil?

          delta = stack_value.to_d - base_value.to_d
          TradeoffNote.new(
            goal_key: goal_key,
            goal_type: goal_type_for(stack_eval),
            direction: direction_for(stack_eval, delta),
            baseline_metric_value: base_value.to_d,
            stack_metric_value: stack_value.to_d,
            metric_delta: delta,
            currency: stack_eval.currency,
            field: stack_eval.details.is_a?(Hash) ? stack_eval.details["field"] : nil
          )
        end
      end

      # Label a delta in the goal's own direction. For maximum-debt goals a smaller
      # value is the win; for everything else a larger value is.
      def direction_for(evaluation, delta)
        return "unchanged" if delta.zero?

        improved = if LOWER_IS_BETTER_GOAL_TYPES.include?(goal_type_for(evaluation))
          delta.negative?
        else
          delta.positive?
        end

        improved ? "improvement" : "regression"
      end

      def baseline_evaluations_by_goal_key
        baseline_run = contributing_runs.find { |run| run.scenario_stack_key == BASELINE_STACK_KEY }
        return {} if baseline_run.nil?

        evaluations_by_goal_key(baseline_run)
      end

      # Map goal_key => evaluation for a run, keeping the LAST by a stable
      # (goal_key, id) order if duplicates somehow exist, so the chosen evaluation
      # never depends on DB row order.
      def evaluations_by_goal_key(run)
        evaluations_for(run)
          .sort_by { |e| [ e.goal_key.to_s, e.id.to_s ] }
          .index_by(&:goal_key)
      end

      # Evaluations for a run as a plain Array (uses an eager-loaded association
      # when present to avoid N+1).
      def evaluations_for(run)
        run.forecast_goal_evaluations.to_a
      end

      # Normalize an evaluation's status to one of the three classes' driving
      # statuses. A missing evaluation (goal the stack never graded) is treated as
      # at_risk — never satisfied.
      def status_for(evaluation)
        return nil if evaluation.nil?

        evaluation.status
      end

      def goal_type_for(evaluation)
        snapshot = evaluation.goal_snapshot
        snapshot.is_a?(Hash) ? snapshot["goal_type"] : nil
      end

      def label_for(run)
        snapshot = run.scenario_stack_snapshot
        snapshot_label = snapshot["label"] if snapshot.is_a?(Hash)
        snapshot_label.presence || run.scenario_stack_key
      end
  end
end
