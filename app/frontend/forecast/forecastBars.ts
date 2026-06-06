// Forecast V2 stacked-bar geometry (Phase 1 ProjectionLab redesign).
//
// Pure math that turns the preloaded `ProjectionBandReadModel` into the
// stacked, gradient bar model the ProjectionLab-style chart renders. It has NO
// React, NO DOM, and NO network — it is a deterministic function of its inputs
// so it can be reasoned about (and later unit-tested) in isolation, exactly like
// the line-chart math in `useProjectionChart` it sits alongside.
//
// Why bars-by-year (not the monthly line): ProjectionLab's "Current Projections"
// dashboard plots net worth as one stacked bar per YEAR, each bar split into
// account-type tiers (cash + investments above zero, debt in orange below zero).
// The forecast band already carries `liquid_cash`, `portfolio_value`, and
// `debt_balance` as separate per-period series, so we can stack those today with
// no backend change; richer per-account-category tiers are the Phase 2 backend
// work. We aggregate the monthly series to a year-end snapshot (the last non-null
// month of each calendar year) because these are STOCK balances — the value AT a
// point in time — so a year-end reading is the correct yearly representative
// (unlike flows such as income/spending, which would need summing and are shown
// in the breakdown panel instead).

import { scaleLinear } from "d3";
import type { PeriodKey, ProjectionBandReadModel } from "./types/readModels";

/** Fixed internal viewBox the bar SVG draws into; scales to its container. */
export const BAR_VIEW = { width: 1000, height: 420 } as const;
export const BAR_MARGIN = { top: 28, right: 16, bottom: 16, left: 16 } as const;

/** A layer contributes its metric value to the stack, added (+1) or subtracted
 *  (-1, drawn below the zero baseline). */
export type StackSign = 1 | -1;
export interface StackLayer {
  readonly key: string;
  readonly sign: StackSign;
}

/** A selectable plot. `net_worth` stacks the three account-type layers; the
 *  others are single-series bars of one stock metric. Flows (income/spending)
 *  are intentionally excluded — they are not stock balances and belong in the
 *  breakdown panel. */
export interface PlotMode {
  readonly key: string;
  readonly stacked: boolean;
  readonly layers: readonly StackLayer[];
}

export const PLOT_MODES: readonly PlotMode[] = [
  {
    key: "net_worth",
    stacked: true,
    layers: [
      { key: "liquid_cash", sign: 1 },
      { key: "portfolio_value", sign: 1 },
      { key: "debt_balance", sign: -1 },
    ],
  },
  {
    key: "liquid_cash",
    stacked: false,
    layers: [{ key: "liquid_cash", sign: 1 }],
  },
  {
    key: "portfolio_value",
    stacked: false,
    layers: [{ key: "portfolio_value", sign: 1 }],
  },
  {
    key: "debt_balance",
    stacked: false,
    layers: [{ key: "debt_balance", sign: 1 }],
  },
];

export function plotModeFor(metricKey: string): PlotMode {
  return PLOT_MODES.find((mode) => mode.key === metricKey) ?? PLOT_MODES[0];
}

/** The plot modes whose every layer series is actually preloaded in the band. */
export function availablePlotModes(
  band: ProjectionBandReadModel,
): readonly PlotMode[] {
  const present = (key: string): boolean =>
    Array.isArray(band.metric_series[key]) || band.selected_metric === key;
  return PLOT_MODES.filter((mode) => mode.layers.every((l) => present(l.key)));
}

function toNumber(value: string | null): number | null {
  if (value === null || value === "") {
    return null;
  }
  const parsed = Number.parseFloat(value);
  return Number.isNaN(parsed) ? null : parsed;
}

function seriesByPeriod(
  band: ProjectionBandReadModel,
  metricKey: string,
): Map<PeriodKey, number | null> {
  const points = band.metric_series[metricKey] ?? band.series ?? [];
  const map = new Map<PeriodKey, number | null>();
  for (const point of points) {
    map.set(point.period_key, toNumber(point.value));
  }
  return map;
}

function yearOf(periodKey: PeriodKey): number {
  return Number.parseInt(periodKey.slice(0, 4), 10);
}

/** One calendar year's year-end snapshot of each requested metric. */
export interface YearAggregate {
  readonly year: number;
  /** Representative (year-end) period key — what a selection commits to. */
  readonly periodKey: PeriodKey;
  /** Metric key -> year-end value (last non-null month of the year; 0 if none). */
  readonly values: Readonly<Record<string, number>>;
}

/**
 * Collapse the band's monthly series into one year-end aggregate per calendar
 * year, reading the last non-null month of each year for every requested metric.
 */
export function aggregateYears(
  band: ProjectionBandReadModel,
  metricKeys: readonly string[],
): YearAggregate[] {
  const maps = new Map<string, Map<PeriodKey, number | null>>();
  for (const key of metricKeys) {
    maps.set(key, seriesByPeriod(band, key));
  }

  // Group the chronological period keys by calendar year, preserving order.
  const byYear = new Map<number, PeriodKey[]>();
  for (const periodKey of band.period_keys) {
    const year = yearOf(periodKey);
    if (!Number.isFinite(year)) {
      continue;
    }
    const list = byYear.get(year) ?? [];
    list.push(periodKey);
    byYear.set(year, list);
  }

  return [...byYear.keys()]
    .sort((a, b) => a - b)
    .map((year) => {
      const periods = byYear.get(year) ?? [];
      const periodKey = periods[periods.length - 1] ?? "";
      const values: Record<string, number> = {};
      for (const key of metricKeys) {
        const map = maps.get(key);
        let resolved = 0;
        for (const period of periods) {
          const value = map?.get(period);
          if (value !== null && value !== undefined) {
            resolved = value;
          }
        }
        values[key] = resolved;
      }
      return { year, periodKey, values };
    });
}

/** One rendered tier of a column (a single account-type segment). */
export interface BarRect {
  readonly key: string;
  readonly sign: StackSign;
  readonly value: number;
  /** Top-left Y in viewBox units. */
  readonly y: number;
  readonly height: number;
}

/** One bar (one calendar year). */
export interface BarColumn {
  readonly index: number;
  readonly year: number;
  readonly periodKey: PeriodKey;
  /** Left edge + width of the bar in viewBox units. */
  readonly x: number;
  readonly width: number;
  /** Horizontal center (guide line + label + net-worth dot anchor). */
  readonly center: number;
  readonly rects: readonly BarRect[];
  /** Signed total (the net worth this column represents). */
  readonly total: number;
  /** Y of the net-worth total on the value scale. */
  readonly netY: number;
}

export interface YTick {
  readonly value: number;
  readonly y: number;
}

export interface BarModel {
  readonly view: { readonly width: number; readonly height: number };
  readonly margin: typeof BAR_MARGIN;
  /** Y of the zero baseline (where positive tiers sit on and debt hangs below). */
  readonly zeroY: number;
  readonly columns: readonly BarColumn[];
  /** Path through each column's net-worth total (stacked mode only). */
  readonly netLinePath: string;
  readonly yTicks: readonly YTick[];
  readonly hasData: boolean;
  /** Ordered, de-duped metric keys in the plot (legend + tooltip order). */
  readonly layerKeys: readonly string[];
}

/**
 * Build the full bar geometry for a plot mode. Positive layers stack upward from
 * the zero baseline; negative layers (debt) stack downward. A 1px gap between
 * tiers gives the crisp ProjectionLab tier separation.
 */
export function buildBarModel(
  aggregates: readonly YearAggregate[],
  mode: PlotMode,
  view: { width: number; height: number } = BAR_VIEW,
): BarModel {
  const innerWidth = view.width - BAR_MARGIN.left - BAR_MARGIN.right;
  const innerHeight = view.height - BAR_MARGIN.top - BAR_MARGIN.bottom;

  let maxPositive = 0;
  let minNegative = 0;
  for (const aggregate of aggregates) {
    let positive = 0;
    let negative = 0;
    let net = 0;
    for (const layer of mode.layers) {
      const signed = layer.sign * (aggregate.values[layer.key] ?? 0);
      net += signed;
      if (signed >= 0) {
        positive += signed;
      } else {
        negative += signed;
      }
    }
    maxPositive = Math.max(maxPositive, positive, net);
    minNegative = Math.min(minNegative, negative, net);
  }
  if (maxPositive === 0 && minNegative === 0) {
    maxPositive = 1;
  }
  const pad = (maxPositive - minNegative) * 0.08 || 1;

  const y = scaleLinear()
    .domain([minNegative - pad, maxPositive + pad])
    .range([BAR_MARGIN.top + innerHeight, BAR_MARGIN.top])
    .nice();
  const zeroY = y(0);

  const count = aggregates.length;
  const step = count > 0 ? innerWidth / count : innerWidth;
  const barWidth = Math.max(2, Math.min(64, step * 0.6));
  const TIER_GAP = 1.5;

  const columns: BarColumn[] = aggregates.map((aggregate, index) => {
    const center = BAR_MARGIN.left + step * (index + 0.5);
    const x = center - barWidth / 2;

    let posCursor = 0;
    let negCursor = 0;
    let net = 0;
    const rects: BarRect[] = mode.layers.map((layer) => {
      const value = aggregate.values[layer.key] ?? 0;
      const signed = layer.sign * value;
      net += signed;
      let yTop: number;
      let yBottom: number;
      if (signed >= 0) {
        const base = posCursor;
        posCursor += signed;
        yTop = y(posCursor);
        yBottom = y(base);
      } else {
        const base = negCursor;
        negCursor += signed;
        yTop = y(base);
        yBottom = y(negCursor);
      }
      const rawHeight = Math.abs(yBottom - yTop);
      const height = rawHeight > TIER_GAP ? rawHeight - TIER_GAP : rawHeight;
      return {
        key: layer.key,
        sign: layer.sign,
        value,
        y: Math.min(yTop, yBottom),
        height,
      };
    });

    return {
      index,
      year: aggregate.year,
      periodKey: aggregate.periodKey,
      x,
      width: barWidth,
      center,
      rects,
      total: net,
      netY: y(net),
    };
  });

  const netLinePath = columns
    .map(
      (column, index) =>
        `${index === 0 ? "M" : "L"}${column.center},${column.netY}`,
    )
    .join(" ");

  const yTicks: YTick[] = y.ticks(4).map((value) => ({ value, y: y(value) }));

  const hasData =
    aggregates.length > 0 &&
    aggregates.some((aggregate) =>
      mode.layers.some((layer) => (aggregate.values[layer.key] ?? 0) !== 0),
    );

  const layerKeys = [...new Set(mode.layers.map((layer) => layer.key))];

  return {
    view,
    margin: BAR_MARGIN,
    zeroY,
    columns,
    netLinePath,
    yTicks,
    hasData,
    layerKeys,
  };
}
