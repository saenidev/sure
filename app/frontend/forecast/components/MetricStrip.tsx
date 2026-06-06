// Forecast V2 MetricStrip (slice C3).
//
// Renders the selected period's key metrics as an aligned strip: each cell shows
// a localized label, the metric value (right-aligned, tabular-nums for column
// alignment), an optional delta vs. a comparison point, and an optional status
// affordance (spec "Forecast Component Contracts" -> `MetricStrip`: "aligned
// metric values, deltas, and status affordances").
//
// Privacy-safe: every value/delta cell carries the global `privacy-sensitive`
// class, so the existing app-wide privacy-mode toggle (html.privacy-mode, seeded
// before first paint by the forecast_inertia layout) blurs them with no
// forecast-specific JS. Tokens only — no raw palette. The strip is a semantic
// <dl> so assistive tech reads label/value pairs; deltas and status get aria
// labels.
//
// Money/runway values arrive as canonical decimal/integer strings from the read
// model (never floats). The strip formats them for display client-side and never
// recomputes financial truth.

import type { JSX } from "react";
import { ft } from "../i18n";
import type { MoneyString, SelectedPeriodMetric } from "../types/readModels";

/** Direction of a metric delta, driving tone + arrow glyph. */
export type MetricDeltaDirection = "up" | "down" | "flat";

/** A metric's change vs. a comparison point (already computed upstream). */
export interface MetricDelta {
  readonly direction: MetricDeltaDirection;
  /** Display-ready delta text (e.g. "+1,200" or "3.4%"); client-formatted. */
  readonly label: string;
  /**
   * Whether an upward direction is good for this metric (net worth up = good;
   * debt up = bad). Drives the tone independent of the arrow direction.
   */
  readonly positiveIsGood?: boolean;
}

/** Optional status affordance shown next to a metric (e.g. a runway warning). */
export interface MetricStatus {
  readonly tone: "positive" | "attention" | "critical" | "neutral";
  readonly label: string;
}

/** One strip entry: a read-model metric plus optional delta/status affordances. */
export interface MetricStripEntryView {
  readonly key: string;
  /** i18n key for the metric label (the client resolves it). */
  readonly labelKey: string;
  /** Canonical value string (decimal money or integer runway); null if absent. */
  readonly value: MoneyString | null;
  readonly delta?: MetricDelta;
  readonly status?: MetricStatus;
}

const STATUS_TEXT_CLASS: Readonly<Record<MetricStatus["tone"], string>> = {
  positive: "text-success",
  attention: "text-warning",
  critical: "text-destructive",
  neutral: "text-subdued",
};

const DELTA_GLYPH: Readonly<Record<MetricDeltaDirection, string>> = {
  up: "↑",
  down: "↓",
  flat: "→",
};

// A delta's tone follows whether the move is good for the metric, not just its
// direction. `flat` is always neutral.
function deltaToneClass(delta: MetricDelta): string {
  if (delta.direction === "flat") {
    return "text-subdued";
  }
  const isGood =
    delta.direction === "up"
      ? (delta.positiveIsGood ?? true)
      : !(delta.positiveIsGood ?? true);
  return isGood ? "text-success" : "text-destructive";
}

// Format a canonical value string for display. Keeps the canonical string as the
// source of truth and never parses it into a float used downstream.
function formatValue(value: MoneyString | null): string {
  if (value === null || value === "") {
    return "—";
  }
  const parsed = Number.parseFloat(value);
  if (Number.isNaN(parsed)) {
    return value;
  }
  return new Intl.NumberFormat(undefined, {
    maximumFractionDigits: 2,
  }).format(parsed);
}

/**
 * Adapts the read model's selected-period metric rows into strip entries. Deltas
 * and status are layered on by callers that have a comparison point; the
 * first-viewport strip renders values + labels only.
 */
export function metricsToStripEntries(
  metrics: readonly SelectedPeriodMetric[],
): MetricStripEntryView[] {
  return metrics.map((metric) => ({
    key: metric.key,
    labelKey: metric.label_key,
    value: metric.value,
  }));
}

export interface MetricStripProps {
  readonly entries: readonly MetricStripEntryView[];
  /** Stable region id for scoped patches / tests. */
  readonly regionKey?: string;
}

export default function MetricStrip({
  entries,
  regionKey = "forecast-metric-strip",
}: MetricStripProps): JSX.Element {
  if (entries.length === 0) {
    return (
      <p
        data-testid={regionKey}
        data-region={regionKey}
        className="rounded-xl border border-primary bg-container p-4 text-sm text-subdued"
      >
        {ft("forecasts.workspace.no_metrics")}
      </p>
    );
  }

  return (
    <dl
      data-testid={regionKey}
      data-region={regionKey}
      aria-label={ft("forecasts.workspace.metric_strip_label")}
      className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4"
    >
      {entries.map((entry) => (
        <div
          key={entry.key}
          data-testid={`forecast-metric-${entry.key}`}
          className="flex flex-col gap-1 rounded-xl border border-primary bg-container p-4"
        >
          <dt className="truncate text-xs text-subdued">
            {ft(entry.labelKey)}
          </dt>
          <dd className="flex items-baseline justify-between gap-2">
            <span className="privacy-sensitive truncate text-lg font-semibold tabular-nums text-primary">
              {formatValue(entry.value)}
            </span>
            {entry.delta ? (
              <span
                className={`privacy-sensitive shrink-0 text-xs font-medium tabular-nums ${deltaToneClass(
                  entry.delta,
                )}`}
              >
                <span aria-hidden="true">
                  {DELTA_GLYPH[entry.delta.direction]}
                </span>
                <span className="ml-0.5">{entry.delta.label}</span>
              </span>
            ) : null}
          </dd>
          {entry.status ? (
            <p
              className={`text-xs font-medium ${STATUS_TEXT_CLASS[entry.status.tone]}`}
            >
              {entry.status.label}
            </p>
          ) : null}
        </div>
      ))}
    </dl>
  );
}
