# frozen_string_literal: true

# THROWAWAY viability spike (Forecast V2 / slice A2).
#
# Authenticated, family-scoped route that renders the Forecast V2 workspace as a
# route-scoped Inertia/Vite/React page instead of an ERB/Turbo surface. It exists
# only to prove the Inertia substrate end-to-end (typed Rails props -> typed
# React page) before the real Phase 2 forecast redesign commits to it.
#
# Hard boundaries this spike must keep:
#
# - Inherits ApplicationController, so it gets the same Authentication +
#   Current.family scoping as /forecast (signed-out users are redirected to the
#   sign-in page; every read is implicitly scoped to the authenticated family).
# - It returns ONLY typed, read-model-shaped MOCK props. It never instantiates or
#   reads the V1 Forecast::Workspace / Forecast::Engine / Forecast::Runner, and
#   never reads or mutates forecast_run_groups / forecast_runs / forecast_days /
#   forecast_months. Those remain the untouched V1 surface served at /forecast.
# - Money is serialized as decimal strings plus an enclosing currency context,
#   never as floats, matching the V2 projection-result contract.
# - The run/as-of date is threaded in explicitly (never read from inside a shared
#   builder), so the mock series is deterministic for a given anchor date.
#
# Not in primary navigation. Delete with the route, the Inertia page, and the
# controller test when the spike is folded into Phase 2 or removed.
class ForecastV2SpikeController < ApplicationController
  # Number of monthly projection periods to mock (the real V2 horizon is 36).
  MOCK_HORIZON_MONTHS = 36

  def show
    anchor = Date.current.beginning_of_month
    currency = Current.family.primary_currency_code

    # layout: false for this slice. The forecast Inertia layout decision (app
    # shell vs. a dedicated forecast_inertia layout) is the explicit deliverable
    # of slice A3; until then we render the bare Inertia root so this controller
    # never depends on the heavy importmap/Turbo application chrome.
    render inertia: "Forecast/Spike", layout: false, props: {
      plan: plan_prop(currency),
      currentPeriodKey: period_key(anchor),
      periodKeys: period_keys(anchor),
      series: series_prop(anchor),
      metrics: metrics_prop(anchor),
      privacy: privacy_prop,
      freshness: freshness_prop(anchor)
    }
  end

  private
    def plan_prop(currency)
      {
        id: "spike_plan",
        label: t("forecast_v2_spike.show.plan_label"),
        currency: currency,
        version: 1
      }
    end

    def period_keys(anchor)
      months(anchor).map { |month| period_key(month) }
    end

    # Compact, chart-ready metric series: one point per period, money as decimal
    # strings. Deterministic given the anchor date so the React page can scrub it
    # with zero network requests.
    def series_prop(anchor)
      months(anchor).each_with_index.map do |month, index|
        {
          periodKey: period_key(month),
          netWorth: decimal(mock_net_worth(index)),
          cash: decimal(mock_cash(index))
        }
      end
    end

    # First-viewport metric strip for the currently selected (current) period.
    def metrics_prop(anchor)
      [
        {
          key: "net_worth",
          label: t("forecast_v2_spike.show.metric_net_worth"),
          value: decimal(mock_net_worth(0))
        },
        {
          key: "cash",
          label: t("forecast_v2_spike.show.metric_cash"),
          value: decimal(mock_cash(0))
        }
      ]
    end

    def privacy_prop
      # Privacy mode in Sure is a client-side (localStorage) preference; the
      # server has no stored privacy flag. The page hydrates from the same source
      # of truth on the client, so the server seeds the default (disabled).
      { enabled: false }
    end

    def freshness_prop(anchor)
      {
        state: "fresh",
        projectedAt: anchor.in_time_zone.iso8601
      }
    end

    def months(anchor)
      MOCK_HORIZON_MONTHS.times.map { |offset| anchor >> offset }
    end

    def period_key(month)
      month.strftime("%Y-%m")
    end

    # Deterministic mock metrics: a smooth upward net-worth ramp and a modest
    # cash float. No randomness, no I/O, no V1 reads.
    def mock_net_worth(index)
      100_000 + (index * 8_420)
    end

    def mock_cash(index)
      25_000 + (index * 250)
    end

    def decimal(integer_amount)
      format("%.2f", integer_amount)
    end
end
