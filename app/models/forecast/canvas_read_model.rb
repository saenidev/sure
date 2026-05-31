module Forecast
  class CanvasReadModel
    COLORS = [
      "var(--color-blue-600)",
      "var(--color-green-600)",
      "var(--color-fuchsia-600)",
      "var(--color-yellow-600)",
      "var(--color-cyan-600)",
      "var(--color-indigo-600)"
    ].freeze
    NEW_SCENARIO_VALUE = "__new__".freeze

    METRICS = [
      [ "net_worth", :money ],
      [ "cash_balance", :money ],
      [ "liquid_balance", :money ],
      [ "portfolio_value", :money ],
      [ "debt_balance", :money ],
      [ "cash_runway_days", :days ]
    ].freeze

    def initialize(workspace)
      @workspace = workspace
      @family = workspace.family
    end

    def payload
      workspace.overview_data? ? latest_run_payload : preview_payload
    end

    def event_marker(event)
      {
        id: event.id,
        date: event.starts_on.iso8601,
        end_date: event.ends_on&.iso8601,
        label: event.name,
        kind: event.forecast_scenario_id.present? ? "scenario" : "event",
        scenario_id: event.forecast_scenario_id,
        scenario: event.forecast_scenario&.name,
        effect_type: event.effect_type,
        status: event.status,
        status_label: I18n.t("forecasts.events.statuses.#{event.status}", default: event.status.to_s.humanize),
        amount: event.amount&.to_f,
        formatted_amount: formatted_event_amount(event),
        effect_label: I18n.t("forecasts.events.effect_types.#{event.effect_type}", default: event.effect_type.to_s.humanize),
        color: event.forecast_scenario&.color.presence || event_color(event),
        edit_url: route_helpers.edit_forecast_event_path(event)
      }
    end

    private
      attr_reader :workspace, :family

      def latest_run_payload
        runs = workspace.comparison_runs.select { |run| run.status == "completed" && months_for(run).any? }
        series = runs.first(COLORS.size).each_with_index.map { |run, index| series_for_run(run, index) }

        {
          source: "latest_run",
          preview: false,
          currency: workspace.currency,
          generated_at: workspace.generated_at&.iso8601,
          generated_label: workspace.generated_at ? I18n.l(workspace.generated_at, format: :long) : nil,
          stale: stale?,
          metrics: metric_options,
          series: with_baseline_deltas(series),
          events: event_markers,
          stacks: stack_summaries(runs),
          draft_options: draft_options,
          labels: labels
        }
      end

      def preview_payload
        start_on = Date.current.beginning_of_month
        months = 37.times.map { |index| start_on + index.months }
        baseline = months.each_with_index.map do |date, index|
          {
            date: date.iso8601,
            net_worth: 92_000 + (index * 1_250),
            cash_balance: 18_000 + (index * 160),
            liquid_balance: 26_000 + (index * 220),
            portfolio_value: 48_000 + (index * 900),
            debt_balance: [ 31_000 - (index * 620), 4_500 ].max,
            cash_runway_days: 120 + (index * 2)
          }
        end

        {
          source: "preview",
          preview: true,
          currency: workspace.currency,
          generated_at: nil,
          generated_label: nil,
          stale: false,
          metrics: metric_options,
          series: [
            series_from_points("baseline", I18n.t("forecasts.comparison.baseline_label"), baseline, 0),
            series_from_points("preview_move", I18n.t("forecasts.canvas.preview_series.move", default: "Preview move"), preview_variant(baseline, -14_000), 1, preview: true),
            series_from_points("preview_drawdown", I18n.t("forecasts.canvas.preview_series.drawdown", default: "Preview drawdown"), preview_variant(baseline, -22_000), 2, preview: true)
          ],
          events: event_markers + preview_events(start_on),
          stacks: [],
          draft_options: draft_options,
          labels: labels
        }
      end

      def preview_variant(points, net_worth_delta)
        points.map.with_index do |point, index|
          point.merge(
            net_worth: point.fetch(:net_worth) + (index >= 6 ? net_worth_delta + ((index - 6) * 700) : 0),
            cash_balance: point.fetch(:cash_balance) + (index >= 6 ? -4_000 : 0),
            liquid_balance: point.fetch(:liquid_balance) + (index >= 6 ? -5_000 : 0),
            portfolio_value: point.fetch(:portfolio_value) + (index >= 10 ? net_worth_delta / 2 : 0),
            cash_runway_days: [ point.fetch(:cash_runway_days) + (index >= 6 ? -24 : 0), 0 ].max
          )
        end
      end

      def preview_events(start_on)
        [
          {
            id: nil,
            date: (start_on + 6.months).iso8601,
            label: I18n.t("forecasts.canvas.preview_events.move", default: "Preview relocation"),
            kind: "preview",
            color: COLORS.second
          },
          {
            id: nil,
            date: (start_on + 10.months).iso8601,
            label: I18n.t("forecasts.canvas.preview_events.drawdown", default: "Preview drawdown"),
            kind: "preview",
            color: COLORS.third
          }
        ]
      end

      def metric_options
        METRICS.map do |metric, format|
          {
            key: metric,
            label: I18n.t("forecasts.canvas.metrics.#{metric}", default: metric.humanize),
            format: format.to_s
          }
        end
      end

      def series_for_run(run, index)
        series_from_points(
          run.scenario_stack_key.presence || "run_#{run.id}",
          stack_label(run),
          months_for(run).map { |month| point_for_month(month) },
          index,
          stack_key: run.scenario_stack_key,
          scenario_ids: scenario_ids_for(run),
          feasibility_status: run.feasibility_status
        )
      end

      def point_for_month(month)
        {
          date: month.period_start_on.iso8601,
          net_worth: month.net_worth,
          cash_balance: month.cash_balance,
          liquid_balance: month.liquid_balance,
          portfolio_value: month.portfolio_value,
          debt_balance: month.debt_balance,
          cash_runway_days: month.cash_runway_days
        }
      end

      def series_from_points(id, label, points, color_index, stack_key: id, scenario_ids: [], feasibility_status: nil, preview: false)
        {
          id: id,
          label: label,
          stack_key: stack_key,
          scenario_ids: scenario_ids,
          feasibility_status: feasibility_status,
          color: COLORS.fetch(color_index % COLORS.size),
          preview: preview,
          metrics: METRICS.to_h do |metric, format|
            [
              metric,
              points.filter_map do |point|
                value = point[metric.to_sym]
                next if value.blank?

                {
                  date: point.fetch(:date),
                  value: value.to_f,
                  formatted: format_value(value, format)
                }
              end
            ]
          end
        }
      end

      def with_baseline_deltas(series)
        baseline = series.find { |candidate| candidate.fetch(:id) == Forecast::Workspace::BASELINE_STACK_KEY } || series.first
        return series unless baseline

        baseline_metrics = baseline.fetch(:metrics).transform_values do |points|
          points.index_by { |point| point.fetch(:date) }
        end

        series.map do |candidate|
          next candidate if candidate.equal?(baseline)

          candidate.merge(
            metrics: candidate.fetch(:metrics).to_h do |metric, points|
              format = METRICS.to_h.fetch(metric)
              baseline_points = baseline_metrics.fetch(metric, {})
              [
                metric,
                points.map do |point|
                  baseline_point = baseline_points[point.fetch(:date)]
                  next point unless baseline_point

                  delta = point.fetch(:value) - baseline_point.fetch(:value)
                  point.merge(
                    delta_from_baseline: delta,
                    formatted_delta: format_value(delta, format)
                  )
                end
              ]
            end
          )
        end
      end

      def event_markers
        family.forecast_events
          .includes(:forecast_scenario)
          .where.not(starts_on: nil)
          .order(:starts_on, :created_at)
          .limit(100)
          .map { |event| event_marker(event) }
      end

      def stack_summaries(runs)
        runs.map do |run|
          months = months_for(run)
          last = months.last
          scenarios = scenario_snapshots_for(run)
          scenario_ids = scenarios.filter_map { |scenario| scenario["id"] || scenario[:id] }
          scenario_names = scenarios.filter_map { |scenario| scenario["name"] || scenario[:name] }
          {
            id: run.scenario_stack_key.presence || "run_#{run.id}",
            label: stack_label(run),
            stack_key: run.scenario_stack_key,
            scenario_ids: scenario_ids,
            source_scenario_id: scenario_ids.one? ? scenario_ids.first : nil,
            source_scenario_ids: scenario_ids,
            scenario_names: scenario_names,
            feasibility_status: run.feasibility_status,
            end_values: last ? {
              net_worth: money_payload(last.net_worth),
              cash_balance: money_payload(last.cash_balance),
              liquid_balance: money_payload(last.liquid_balance),
              portfolio_value: money_payload(last.portfolio_value),
              debt_balance: money_payload(last.debt_balance),
              cash_runway_days: days_payload(last.cash_runway_days)
            } : {},
            low_points: {
              cash_balance: money_payload(months.map(&:cash_balance).min),
              liquid_balance: money_payload(months.map(&:liquid_balance).min),
              cash_runway_days: days_payload(months.filter_map(&:cash_runway_days).min)
            },
            goal_status_counts: goal_status_counts(run),
            risk_flags: Array(run.risk_flags).map { |flag| flag.is_a?(Hash) ? flag["type"] : flag }.compact_blank.uniq
          }
        end
      end

      def draft_options
        {
          effect_types: ForecastEvent::EFFECT_TYPES,
          amount_effect_types: ForecastEvent::AMOUNT_EFFECT_TYPES,
          category_effect_types: %w[income expense],
          transfer_effect_types: %w[transfer],
          statuses: ForecastEvent::STATUSES,
          recurrence_frequencies: %w[weekly monthly],
          currencies: [ workspace.currency ],
          create_event_url: route_helpers.forecast_canvas_drafts_path,
          fork_url: route_helpers.forecast_canvas_forks_path,
          new_scenario_value: NEW_SCENARIO_VALUE,
          scenario_targets: family.forecast_scenarios.ordered.map do |scenario|
            {
              id: scenario.id,
              label: scenario.name,
              status: scenario.status,
              status_label: I18n.t("forecasts.scenarios.statuses.#{scenario.status}", default: scenario.status.humanize),
              starts_on: scenario.starts_on&.iso8601,
              ends_on: scenario.ends_on&.iso8601,
              color: scenario.color,
              edit_url: route_helpers.edit_forecast_scenario_path(scenario)
            }
          end,
          accounts: family.accounts.visible.alphabetically.map do |account|
            {
              id: account.id,
              label: account.name,
              currency: account.currency
            }
          end,
          categories: family.categories.alphabetically.map do |category|
            {
              id: category.id,
              label: category.name,
              color: category.color
            }
          end
        }
      end

      def labels
        {
          source: {
            latest_run: I18n.t("forecasts.canvas.source.latest_run", default: "Using the latest completed forecast run."),
            preview: I18n.t("forecasts.canvas.source.preview", default: "Using preview data.")
          },
          event_empty: I18n.t("forecasts.canvas.event_empty", default: "No dated events in this range."),
          line_empty: I18n.t("forecasts.canvas.line_empty", default: "Turn on at least one scenario."),
          metric_empty: I18n.t("forecasts.canvas.metric_empty", default: "No projection points for this metric."),
          selection_empty: I18n.t("forecasts.canvas.selection.empty", default: "Select a point"),
          draft: I18n.t("forecasts.canvas.selection.draft", default: "Draft marker"),
          preview: I18n.t("forecasts.canvas.preview_notice", default: "Preview data is shown because no completed projection exists yet."),
          stale: I18n.t("forecasts.canvas.stale_notice", default: "Inputs changed after this forecast was generated."),
          prototype: I18n.t("forecasts.canvas.prototype_label", default: "Preview"),
          inspector: {
            delta_label: I18n.t("forecasts.canvas.inspector.delta_label", default: "Vs baseline"),
            no_delta: I18n.t("forecasts.canvas.inspector.no_delta", default: "Baseline series"),
            metrics_heading: I18n.t("forecasts.canvas.inspector.metrics_heading", default: "Metric values"),
            stack_heading: I18n.t("forecasts.canvas.inspector.stack_heading", default: "Scenario stack"),
            end_heading: I18n.t("forecasts.canvas.inspector.end_heading", default: "End of horizon"),
            low_heading: I18n.t("forecasts.canvas.inspector.low_heading", default: "Lowest point"),
            goals_heading: I18n.t("forecasts.canvas.inspector.goals_heading", default: "Goal results"),
            risks_heading: I18n.t("forecasts.canvas.inspector.risks_heading", default: "Risk flags"),
            feasibility: I18n.t("forecasts.canvas.inspector.feasibility", default: "Feasibility"),
            inspect: I18n.t("forecasts.canvas.inspector.inspect", default: "Inspect"),
            none: I18n.t("forecasts.canvas.inspector.none", default: "None"),
            event_heading: I18n.t("forecasts.canvas.inspector.event_heading", default: "Event details"),
            edit_event: I18n.t("forecasts.canvas.inspector.edit_event", default: "Edit event"),
            amount: I18n.t("forecasts.canvas.inspector.amount", default: "Amount"),
            effect: I18n.t("forecasts.canvas.inspector.effect", default: "Effect"),
            scenario: I18n.t("forecasts.canvas.inspector.scenario", default: "Scenario"),
            status: I18n.t("forecasts.canvas.inspector.status", default: "Status")
          },
          forks: {
            heading: I18n.t("forecasts.canvas.forks.heading", default: "Fork scenario"),
            name: I18n.t("forecasts.canvas.forks.name", default: "Name"),
            source: I18n.t("forecasts.canvas.forks.source", default: "Source"),
            baseline: I18n.t("forecasts.canvas.forks.baseline", default: "Baseline"),
            selected_stack: I18n.t("forecasts.canvas.forks.selected_stack", default: "Selected stack"),
            save: I18n.t("forecasts.canvas.forks.save", default: "Create fork"),
            created: I18n.t("forecasts.canvas.forks.created", default: "Scenario created. Regenerate the forecast to update projections."),
            default_name: I18n.t("forecasts.canvas.forks.default_name", default: "Canvas scenario"),
            default_stack_name: I18n.t("forecasts.canvas.forks.default_stack_name", default: "Canvas stack fork"),
            disabled_note: I18n.t("forecasts.canvas.forks.disabled_note", default: "Forks copied from existing scenarios start disabled so they do not double-count until activated."),
            edit_scenario: I18n.t("forecasts.canvas.forks.edit_scenario", default: "Edit scenario")
          }
        }
      end

      def months_for(run)
        if run.forecast_months.loaded?
          run.forecast_months.to_a.sort_by(&:period_start_on)
        else
          run.forecast_months.order(:period_start_on).to_a
        end
      end

      def stack_label(run)
        return I18n.t("forecasts.comparison.baseline_label") if run.scenario_stack_key == Forecast::Workspace::BASELINE_STACK_KEY

        names = scenario_snapshots_for(run).filter_map { |scenario| scenario["name"] || scenario[:name] }
        names.any? ? names.join(" + ") : run.scenario_stack_key.to_s.humanize
      end

      def scenario_ids_for(run)
        scenario_snapshots_for(run).filter_map { |scenario| scenario["id"] || scenario[:id] }
      end

      def scenario_snapshots_for(run)
        run.scenario_stack_snapshot.is_a?(Hash) ? Array(run.scenario_stack_snapshot["scenarios"]) : []
      end

      def goal_status_counts(run)
        evaluations = if run.forecast_goal_evaluations.loaded?
          run.forecast_goal_evaluations.to_a
        else
          run.forecast_goal_evaluations.to_a
        end

        ForecastGoalEvaluation::STATUSES.to_h do |status|
          [ status, evaluations.count { |evaluation| evaluation.status == status } ]
        end
      end

      def stale?
        false
      end

      def event_color(event)
        event.forecast_scenario_id.present? ? COLORS.second : COLORS.fourth
      end

      def formatted_event_amount(event)
        return if event.amount.blank?

        Money.new(event.amount, event.currency || workspace.currency).format
      end

      def money_payload(value)
        return if value.blank?

        {
          value: value.to_f,
          formatted: format_value(value, :money)
        }
      end

      def days_payload(value)
        return if value.blank?

        {
          value: value.to_i,
          formatted: format_value(value, :days)
        }
      end

      def format_value(value, format)
        case format
        when :days
          I18n.t("forecasts.canvas.days", count: value.to_i, default: "#{value.to_i} days")
        else
          Money.new(value, workspace.currency).format
        end
      end

      def route_helpers
        Rails.application.routes.url_helpers
      end
  end
end
