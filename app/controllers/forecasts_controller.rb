class ForecastsController < ApplicationController
  def show
    @workspace = Forecast::Workspace.new(family: Current.family)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("forecasts.show.title"), nil ] ]
  end

  def canvas
    @workspace = Forecast::Workspace.new(family: Current.family)
    @canvas_payload = forecast_canvas_preview_payload(@workspace)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("forecasts.show.title"), forecast_path ],
      [ t("forecasts.canvas.title"), nil ]
    ]
  end

  # Lazy-loaded panel body for a single workspace tab. The show page renders only
  # the active tab eagerly; every other tab is a lazy Turbo Frame that fetches its
  # body here when first shown, so one /forecast load no longer renders all nine
  # panels (and their builders) server-side at once. Scoped to Current.family and
  # the tab allowlist (ForecastsHelper::TAB_PARTIALS), so no untrusted id reaches
  # the render path. Legacy tab ids are accepted and mapped to the newer grouped
  # decision areas so old links keep working.
  def tab
    @workspace = Forecast::Workspace.new(family: Current.family)
    unless Forecast::Workspace::TAB_IDS.include?(params[:tab_id].to_s) ||
        Forecast::Workspace::TAB_ALIASES.key?(params[:tab_id].to_s)
      return head(:not_found)
    end

    @tab_id = @workspace.canonical_tab_id(params[:tab_id])
    render layout: false
  end

  private
    CANVAS_PREVIEW_COLORS = [
      "var(--color-blue-600)",
      "var(--color-green-600)",
      "var(--color-fuchsia-600)",
      "var(--color-yellow-600)",
      "var(--color-cyan-600)"
    ].freeze

    CANVAS_PREVIEW_METRICS = [
      [ "net_worth", :money ],
      [ "cash_balance", :money ],
      [ "debt_balance", :money ],
      [ "cash_runway_days", :days ]
    ].freeze

    def forecast_canvas_preview_payload(workspace)
      if workspace.overview_data?
        live_forecast_canvas_preview_payload(workspace)
      else
        demo_forecast_canvas_preview_payload(workspace.currency)
      end
    end

    def live_forecast_canvas_preview_payload(workspace)
      runs = workspace.comparison_runs.select { |run| run.status == "completed" && months_for_canvas(run).any? }
      runs = [ workspace.baseline_run ].compact if runs.blank?

      series = runs.first(CANVAS_PREVIEW_COLORS.size).each_with_index.map do |run, index|
        canvas_series_for_run(run, index)
      end

      if series.one?
        series.concat(derived_canvas_preview_series(series.first))
      end

      {
        source: "latest_run",
        currency: workspace.currency,
        generated_at: workspace.generated_at&.iso8601,
        generated_label: workspace.generated_at.present? ? l(workspace.generated_at, format: :long) : nil,
        metrics: canvas_metric_options,
        labels: canvas_preview_labels,
        series: series,
        events: canvas_events_from_family(workspace.family),
        empty: false
      }
    end

    def demo_forecast_canvas_preview_payload(currency)
      start_on = Date.current.beginning_of_month
      months = 37.times.map { |index| start_on + index.months }

      baseline = months.each_with_index.map do |date, index|
        {
          date: date.iso8601,
          net_worth: 92_000 + (index * 1_250) + Math.sin(index / 2.5) * 2_500,
          cash_balance: 18_000 + (index * 160) - Math.sin(index / 3.0) * 1_200,
          debt_balance: [ 31_000 - (index * 620), 4_500 ].max,
          cash_runway_days: 120 + (index * 2)
        }
      end

      country_move = baseline.map.with_index do |point, index|
        shock = index >= 7 ? -14_000 + ((index - 7) * 780) : 0
        point.merge(
          net_worth: point[:net_worth] + shock,
          cash_balance: point[:cash_balance] + (index == 7 ? -11_000 : index > 7 ? -5_500 : 0),
          cash_runway_days: point[:cash_runway_days] - (index >= 7 ? 34 : 0)
        )
      end

      market_drawdown = baseline.map.with_index do |point, index|
        drawdown = index >= 12 ? -22_000 + ((index - 12) * 900) : 0
        point.merge(net_worth: point[:net_worth] + drawdown)
      end

      {
        source: "demo",
        currency: currency,
        generated_at: nil,
        generated_label: nil,
        metrics: canvas_metric_options,
        labels: canvas_preview_labels,
        series: [
          canvas_series_from_points("baseline", t("forecasts.comparison.baseline_label"), baseline, 0),
          canvas_series_from_points("country_move", t("forecasts.canvas.demo_series.country_move"), country_move, 1, prototype: true),
          canvas_series_from_points("market_drawdown", t("forecasts.canvas.demo_series.market_drawdown"), market_drawdown, 2, prototype: true)
        ],
        events: [
          { date: (start_on + 7.months).iso8601, label: t("forecasts.canvas.demo_events.move"), kind: "scenario", color: CANVAS_PREVIEW_COLORS.second },
          { date: (start_on + 12.months).iso8601, label: t("forecasts.canvas.demo_events.drawdown"), kind: "scenario", color: CANVAS_PREVIEW_COLORS.third },
          { date: (start_on + 20.months).iso8601, label: t("forecasts.canvas.demo_events.raise"), kind: "event", color: CANVAS_PREVIEW_COLORS.fourth }
        ],
        empty: true
      }
    end

    def canvas_series_for_run(run, index)
      canvas_series_from_points(
        run.scenario_stack_key.presence || "run_#{run.id}",
        canvas_stack_label(run),
        months_for_canvas(run).map do |month|
          {
            date: month.period_start_on.iso8601,
            net_worth: month.net_worth.to_d,
            cash_balance: month.cash_balance.to_d,
            debt_balance: month.debt_balance.to_d,
            cash_runway_days: month.cash_runway_days
          }
        end,
        index
      )
    end

    def canvas_series_from_points(id, label, points, color_index, prototype: false)
      {
        id: id,
        label: label,
        color: CANVAS_PREVIEW_COLORS.fetch(color_index % CANVAS_PREVIEW_COLORS.size),
        prototype: prototype,
        metrics: CANVAS_PREVIEW_METRICS.to_h do |metric, format|
          [
            metric,
            points.filter_map do |point|
              value = point[metric.to_sym]
              next if value.blank?

              {
                date: point[:date],
                value: value.to_f,
                formatted: canvas_format_value(value, format)
              }
            end
          ]
        end
      }
    end

    def derived_canvas_preview_series(baseline)
      downside = derive_canvas_series(baseline, "prototype_downside", t("forecasts.canvas.derived_series.downside"), 2) do |metric, point, index|
        value = point.fetch(:value) { point.fetch("value") }
        case metric
        when "net_worth" then value - 8_000 - (index * 350)
        when "cash_balance" then value - 4_000
        when "debt_balance" then value + 3_000
        when "cash_runway_days" then [ value - 35, 0 ].max
        end
      end

      upside = derive_canvas_series(baseline, "prototype_upside", t("forecasts.canvas.derived_series.upside"), 1) do |metric, point, index|
        value = point.fetch(:value) { point.fetch("value") }
        case metric
        when "net_worth" then value + 6_000 + (index * 420)
        when "cash_balance" then value + 2_500
        when "debt_balance" then [ value - 4_000, 0 ].max
        when "cash_runway_days" then value + 45
        end
      end

      [ upside, downside ]
    end

    def derive_canvas_series(baseline, id, label, color_index)
      {
        id: id,
        label: label,
        color: CANVAS_PREVIEW_COLORS.fetch(color_index),
        prototype: true,
        metrics: baseline.fetch(:metrics).to_h do |metric, points|
          format = CANVAS_PREVIEW_METRICS.to_h.fetch(metric)
          [
            metric,
            points.each_with_index.map do |point, index|
              value = yield(metric, point, index)
              {
                date: point.fetch(:date) { point.fetch("date") },
                value: value.to_f,
                formatted: canvas_format_value(value, format)
              }
            end
          ]
        end
      }
    end

    def canvas_metric_options
      CANVAS_PREVIEW_METRICS.map do |metric, format|
        {
          key: metric,
          label: t("forecasts.canvas.metrics.#{metric}"),
          format: format.to_s
        }
      end
    end

    def canvas_preview_labels
      {
        source: {
          latest_run: t("forecasts.canvas.source.latest_run"),
          demo: t("forecasts.canvas.source.demo")
        },
        generated: t("forecasts.canvas.generated", datetime: "%{datetime}"),
        event_empty: t("forecasts.canvas.event_empty"),
        selection_empty: t("forecasts.canvas.selection.empty"),
        draft: t("forecasts.canvas.selection.draft"),
        prototype: t("forecasts.canvas.prototype_label")
      }
    end

    def canvas_events_from_family(family)
      family.forecast_events
        .includes(:forecast_scenario)
        .where.not(starts_on: nil)
        .order(:starts_on)
        .limit(25)
        .map do |event|
          {
            date: event.starts_on.iso8601,
            label: event.name,
            kind: event.forecast_scenario_id.present? ? "scenario" : "event",
            scenario: event.forecast_scenario&.name,
            color: event.forecast_scenario_id.present? ? CANVAS_PREVIEW_COLORS.second : CANVAS_PREVIEW_COLORS.fourth
          }
        end
    end

    def months_for_canvas(run)
      if run.forecast_months.loaded?
        run.forecast_months.to_a.sort_by(&:period_start_on)
      else
        run.forecast_months.order(:period_start_on).to_a
      end
    end

    def canvas_stack_label(run)
      return t("forecasts.comparison.baseline_label") if run.scenario_stack_key == Forecast::Workspace::BASELINE_STACK_KEY

      scenarios = run.scenario_stack_snapshot.is_a?(Hash) ? Array(run.scenario_stack_snapshot["scenarios"]) : []
      names = scenarios.map { |scenario| scenario["name"] }.compact_blank
      names.any? ? names.join(" + ") : run.scenario_stack_key.to_s.humanize
    end

    def canvas_format_value(value, format)
      case format
      when :days
        t("forecasts.canvas.days", count: value.to_i)
      else
        Money.new(value, @workspace&.currency || Current.family.currency).format(no_cents: true)
      end
    end
end
