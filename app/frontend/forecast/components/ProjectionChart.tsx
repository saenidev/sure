// Forecast V2 ProjectionChart — ProjectionLab-style stacked gradient bars
// (Phase 1 redesign).
//
// Replaces the original thin-line chart with ProjectionLab's "Current
// Projections" dashboard look: one stacked bar per YEAR, split into account-type
// tiers — cash + investments in a cyan→indigo gradient above the zero baseline,
// debt in orange below it — with a net-worth line riding the bar tops, a
// vertical scrub guide + floating tooltip, a "Plot" selector, and a legend.
//
// All geometry comes from `forecastBars` (pure math); this component owns only
// the SVG/DOM + interaction. Scrubbing stays LOCAL with zero network: pointer
// move walks an ephemeral hover column; a press / arrow keys SETTLE the selection
// and report the column's year-end period key up through `onSelectPeriod` (the
// only cache-fetch path). The required region/testid contract from the proof
// slice is preserved: `forecast-projection-chart`, `forecast-chart-scrubber`,
// `forecast-chart-marker`, `forecast-chart-value`.
//
// Colors are forecast-scoped raw hexes (the faithful ProjectionLab palette the
// user chose), kept entirely inside this route's component tree so the global
// Sure design system is untouched.

import {
  type JSX,
  type KeyboardEvent,
  type PointerEvent,
  useCallback,
  useMemo,
  useState,
} from "react";
import {
  BAR_VIEW,
  aggregateYears,
  availablePlotModes,
  buildBarModel,
  plotModeFor,
} from "../forecastBars";
import { ft } from "../i18n";
import type { ProjectionBandReadModel } from "../types/readModels";

// The faithful ProjectionLab tier palette, scoped to this component.
const SEGMENT_COLORS: Readonly<
  Record<string, { from: string; to: string; solid: string }>
> = {
  liquid_cash: { from: "#818CF8", to: "#4F46E5", solid: "#6366F1" },
  portfolio_value: { from: "#2DD4BF", to: "#0D9488", solid: "#14B8A6" },
  debt_balance: { from: "#FDBA74", to: "#F97316", solid: "#FB923C" },
};
const FALLBACK_COLOR = { from: "#A5B4FC", to: "#6366F1", solid: "#6366F1" };

function colorFor(key: string) {
  return SEGMENT_COLORS[key] ?? FALLBACK_COLOR;
}

function makeFormatters(currency?: string) {
  const build = (opts: Intl.NumberFormatOptions): Intl.NumberFormat => {
    try {
      return new Intl.NumberFormat(
        undefined,
        currency ? { style: "currency", currency, ...opts } : opts,
      );
    } catch {
      return new Intl.NumberFormat(undefined, opts);
    }
  };
  const compact = build({ notation: "compact", maximumFractionDigits: 1 });
  const full = build({ maximumFractionDigits: 0 });
  return {
    compact: (n: number) => compact.format(n),
    full: (n: number) => full.format(n),
  };
}

// PL-style plot selector: a rounded pill with a "Plot" prefix and a native
// <select> for accessibility, restyled to look like ProjectionLab's dropdown.
function PlotSelector({
  band,
  selectedKey,
  onSelect,
}: {
  readonly band: ProjectionBandReadModel;
  readonly selectedKey: string;
  readonly onSelect: (key: string) => void;
}): JSX.Element {
  const modes = availablePlotModes(band);
  return (
    <label className="inline-flex items-center gap-2 rounded-full border border-[#E3E8EF] bg-white px-3 py-1.5 text-sm shadow-[0_1px_2px_rgba(15,23,42,0.04)]">
      <span className="text-[#64748B]">{ft("forecasts.chart.plot_label")}</span>
      <select
        data-testid="forecast-chart-plot"
        aria-label={ft("forecasts.chart.plot_label")}
        value={selectedKey}
        onChange={(event) => onSelect(event.target.value)}
        className="cursor-pointer appearance-none bg-transparent pr-4 font-semibold text-[#0F172A] focus:outline-none"
      >
        {modes.map((mode) => (
          <option key={mode.key} value={mode.key}>
            {ft(`forecasts.chart.plot.${mode.key}`)}
          </option>
        ))}
      </select>
    </label>
  );
}

export interface ProjectionChartProps {
  readonly band: ProjectionBandReadModel;
  readonly selectedPeriodKey: string | null;
  readonly onSelectPeriod: (periodKey: string) => void;
  readonly selectedMetric: string;
  readonly onSelectMetric: (metric: string) => void;
  /** ISO-4217 currency for value formatting (from the plan read model). */
  readonly currency?: string;
  readonly regionKey?: string;
  readonly cacheKey?: string;
}

export default function ProjectionChart({
  band,
  selectedPeriodKey,
  onSelectPeriod,
  selectedMetric,
  onSelectMetric,
  currency,
  regionKey = "forecast-projection-chart",
  cacheKey,
}: ProjectionChartProps): JSX.Element {
  const mode = plotModeFor(selectedMetric);
  const fmt = useMemo(() => makeFormatters(currency), [currency]);

  const model = useMemo(() => {
    const aggregates = aggregateYears(
      band,
      mode.layers.map((layer) => layer.key),
    );
    return buildBarModel(aggregates, mode);
  }, [band, mode]);

  // Resolve the selected column from the store's settled period key: exact
  // year-end match, else any column in the same year, else the last column.
  const selectedIndex = useMemo(() => {
    if (model.columns.length === 0) {
      return -1;
    }
    if (selectedPeriodKey) {
      const exact = model.columns.findIndex(
        (column) => column.periodKey === selectedPeriodKey,
      );
      if (exact >= 0) {
        return exact;
      }
      const year = Number.parseInt(selectedPeriodKey.slice(0, 4), 10);
      const byYear = model.columns.findIndex((column) => column.year === year);
      if (byYear >= 0) {
        return byYear;
      }
    }
    return model.columns.length - 1;
  }, [model.columns, selectedPeriodKey]);

  // Ephemeral hover column, LOCAL to the chart — never touches the store, so a
  // bare scrub issues zero network. A settled commit clears it.
  const [hoverIndex, setHoverIndex] = useState<number | null>(null);
  const activeIndex = hoverIndex ?? selectedIndex;
  const activeColumn = model.columns[activeIndex] ?? null;

  const nearestIndex = useCallback(
    (clientX: number, target: HTMLElement): number => {
      const rect = target.getBoundingClientRect();
      if (rect.width === 0 || model.columns.length === 0) {
        return -1;
      }
      const viewX = ((clientX - rect.left) / rect.width) * BAR_VIEW.width;
      let best = -1;
      let bestDistance = Number.POSITIVE_INFINITY;
      for (const column of model.columns) {
        const distance = Math.abs(column.center - viewX);
        if (distance < bestDistance) {
          bestDistance = distance;
          best = column.index;
        }
      }
      return best;
    },
    [model.columns],
  );

  const handlePointerMove = useCallback(
    (event: PointerEvent<HTMLDivElement>): void => {
      const index = nearestIndex(event.clientX, event.currentTarget);
      if (index >= 0) {
        setHoverIndex(index);
      }
    },
    [nearestIndex],
  );

  const commit = useCallback(
    (index: number): void => {
      const column = model.columns[index];
      if (column) {
        setHoverIndex(null);
        onSelectPeriod(column.periodKey);
      }
    },
    [model.columns, onSelectPeriod],
  );

  const handlePointerDown = useCallback(
    (event: PointerEvent<HTMLDivElement>): void => {
      const index = nearestIndex(event.clientX, event.currentTarget);
      if (index >= 0) {
        commit(index);
      }
    },
    [nearestIndex, commit],
  );

  const handleKeyDown = useCallback(
    (event: KeyboardEvent<HTMLDivElement>): void => {
      if (model.columns.length === 0) {
        return;
      }
      const current = activeIndex >= 0 ? activeIndex : 0;
      const clamp = (index: number) =>
        Math.min(model.columns.length - 1, Math.max(0, index));
      let next: number | null = null;
      if (event.key === "ArrowRight" || event.key === "ArrowUp") {
        next = clamp(current + 1);
      } else if (event.key === "ArrowLeft" || event.key === "ArrowDown") {
        next = clamp(current - 1);
      } else if (event.key === "Home") {
        next = 0;
      } else if (event.key === "End") {
        next = model.columns.length - 1;
      }
      if (next !== null) {
        event.preventDefault();
        commit(next);
      }
    },
    [model.columns.length, activeIndex, commit],
  );

  if (model.columns.length === 0) {
    return (
      <section
        data-testid={regionKey}
        data-region={regionKey}
        data-cache-key={cacheKey}
        className="rounded-2xl border border-[#E3E8EF] bg-white p-6 text-sm text-[#64748B]"
      >
        {ft("forecasts.chart.empty")}
      </section>
    );
  }

  const pctX = (value: number) => `${(value / BAR_VIEW.width) * 100}%`;
  const pctY = (value: number) => `${(value / BAR_VIEW.height) * 100}%`;
  const activeValue = activeColumn ? fmt.full(activeColumn.total) : "—";
  // Keep the tooltip inside the plot box near the edges.
  const tooltipLeftPct = activeColumn
    ? Math.min(86, Math.max(14, (activeColumn.center / BAR_VIEW.width) * 100))
    : 50;

  return (
    <section
      data-testid={regionKey}
      data-region={regionKey}
      data-cache-key={cacheKey}
      data-selected-metric={mode.key}
      aria-label={ft("forecasts.chart.title")}
      className="flex flex-col gap-4 rounded-2xl border border-[#E3E8EF] bg-white p-5 shadow-[0_1px_3px_rgba(15,23,42,0.04)] sm:p-6"
    >
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex flex-col gap-1">
          <h2 className="text-base font-semibold text-[#0F172A]">
            {ft("forecasts.chart.title")}
          </h2>
          <p
            data-testid="forecast-chart-value"
            className="privacy-sensitive text-2xl font-bold tabular-nums text-[#0F172A]"
          >
            {activeValue}
            {activeColumn ? (
              <span className="ml-2 align-middle text-sm font-medium text-[#94A3B8]">
                {activeColumn.year}
              </span>
            ) : null}
          </p>
        </div>
        <PlotSelector
          band={band}
          selectedKey={mode.key}
          onSelect={onSelectMetric}
        />
      </header>

      <div className="relative pb-6 pl-14">
        <div className="relative h-[340px] w-full">
          <svg
            data-testid="forecast-chart-svg"
            aria-hidden="true"
            viewBox={`0 0 ${BAR_VIEW.width} ${BAR_VIEW.height}`}
            preserveAspectRatio="none"
            className="h-full w-full overflow-visible"
          >
            <defs>
              {model.layerKeys.map((key) => {
                const color = colorFor(key);
                return (
                  <linearGradient
                    key={key}
                    id={`fbar-${key}`}
                    x1="0"
                    y1="0"
                    x2="0"
                    y2="1"
                  >
                    <stop offset="0%" stopColor={color.from} />
                    <stop offset="100%" stopColor={color.to} />
                  </linearGradient>
                );
              })}
            </defs>

            {/* Horizontal gridlines. */}
            {model.yTicks.map((tick) => (
              <line
                key={`grid-${tick.value}`}
                x1={model.margin.left}
                x2={BAR_VIEW.width - model.margin.right}
                y1={tick.y}
                y2={tick.y}
                stroke="#EEF2F6"
                strokeWidth={1}
                vectorEffect="non-scaling-stroke"
              />
            ))}

            {/* Zero baseline. */}
            <line
              x1={model.margin.left}
              x2={BAR_VIEW.width - model.margin.right}
              y1={model.zeroY}
              y2={model.zeroY}
              stroke="#CBD5E1"
              strokeWidth={1}
              vectorEffect="non-scaling-stroke"
            />

            {/* Bars (one stacked column per year). */}
            {model.columns.map((column) => {
              const dim = activeColumn !== null && column.index !== activeIndex;
              return (
                <g key={column.periodKey} opacity={dim ? 0.78 : 1}>
                  {column.rects.map((rect) =>
                    rect.height <= 0 ? null : (
                      <rect
                        key={rect.key}
                        x={column.x}
                        y={rect.y}
                        width={column.width}
                        height={rect.height}
                        rx={5}
                        fill={`url(#fbar-${rect.key})`}
                      />
                    ),
                  )}
                </g>
              );
            })}

            {/* Net-worth line riding the bar totals (stacked mode only). */}
            {mode.stacked && model.columns.length > 1 ? (
              <path
                d={model.netLinePath}
                fill="none"
                stroke="#0F172A"
                strokeOpacity={0.55}
                strokeWidth={2}
                strokeLinecap="round"
                strokeLinejoin="round"
                vectorEffect="non-scaling-stroke"
              />
            ) : null}

            {/* Active scrub guide + marker. */}
            {activeColumn ? (
              <g>
                <line
                  x1={activeColumn.center}
                  x2={activeColumn.center}
                  y1={model.margin.top}
                  y2={BAR_VIEW.height - model.margin.bottom}
                  stroke="#94A3B8"
                  strokeDasharray="4 4"
                  strokeWidth={1}
                  vectorEffect="non-scaling-stroke"
                />
                <circle
                  data-testid="forecast-chart-marker"
                  cx={activeColumn.center}
                  cy={activeColumn.netY}
                  r={5}
                  fill="#FFFFFF"
                  stroke="#0F172A"
                  strokeWidth={2}
                  vectorEffect="non-scaling-stroke"
                />
              </g>
            ) : null}
          </svg>

          {/* Y-axis value labels (HTML overlay, percentage-positioned so they
              stay crisp and aligned as the SVG scales). */}
          {model.yTicks.map((tick) => (
            <span
              key={`ylabel-${tick.value}`}
              className="privacy-sensitive pointer-events-none absolute -translate-x-full -translate-y-1/2 pr-2 text-right text-[11px] tabular-nums text-[#94A3B8]"
              style={{ top: pctY(tick.y), left: 0 }}
            >
              {fmt.compact(tick.value)}
            </span>
          ))}

          {/* X-axis year labels. */}
          {model.columns.map((column, index) => {
            const showEvery = Math.ceil(model.columns.length / 12);
            if (index % showEvery !== 0 && index !== model.columns.length - 1) {
              return null;
            }
            return (
              <span
                key={`xlabel-${column.periodKey}`}
                className="pointer-events-none absolute top-full -translate-x-1/2 pt-1.5 text-[11px] tabular-nums text-[#94A3B8]"
                style={{ left: pctX(column.center) }}
              >
                {column.year}
              </span>
            );
          })}

          {/* Floating tooltip for the active column. */}
          {activeColumn ? (
            <div
              className="pointer-events-none absolute top-2 z-10 -translate-x-1/2 rounded-xl border border-[#E3E8EF] bg-white/95 px-3 py-2 text-xs shadow-[0_8px_24px_rgba(15,23,42,0.12)] backdrop-blur"
              style={{ left: `${tooltipLeftPct}%` }}
            >
              <p className="mb-1 font-semibold text-[#0F172A]">
                {activeColumn.year}
              </p>
              <p className="mb-1.5 flex items-center justify-between gap-4">
                <span className="text-[#64748B]">
                  {ft("forecasts.chart.tooltip_total")}
                </span>
                <span className="privacy-sensitive font-semibold tabular-nums text-[#0F172A]">
                  {fmt.full(activeColumn.total)}
                </span>
              </p>
              {activeColumn.rects.map((rect) => (
                <p
                  key={rect.key}
                  className="flex items-center justify-between gap-4"
                >
                  <span className="flex items-center gap-1.5 text-[#64748B]">
                    <span
                      aria-hidden="true"
                      className="inline-block size-2 rounded-full"
                      style={{ backgroundColor: colorFor(rect.key).solid }}
                    />
                    {ft(`forecasts.chart.segment.${rect.key}`)}
                  </span>
                  <span className="privacy-sensitive tabular-nums text-[#334155]">
                    {fmt.full(rect.value)}
                  </span>
                </p>
              ))}
            </div>
          ) : null}

          {/* Interactive scrub layer: owns focus + pointer + keyboard. The SVG
              underneath is purely presentational. Local hover/scrub is zero
              network; a press / arrow commits the settled selection. */}
          <div
            data-testid="forecast-chart-scrubber"
            role="slider"
            tabIndex={0}
            aria-label={ft("forecasts.chart.scrubber_label")}
            aria-valuemin={0}
            aria-valuemax={Math.max(0, model.columns.length - 1)}
            aria-valuenow={activeIndex >= 0 ? activeIndex : 0}
            aria-valuetext={ft("forecasts.chart.selected_period", {
              period: activeColumn?.year ?? "—",
              value: activeValue,
            })}
            className="absolute inset-0 cursor-crosshair touch-none rounded-lg outline-none focus-visible:ring-2 focus-visible:ring-[#6366F1]/40"
            onPointerMove={handlePointerMove}
            onPointerDown={handlePointerDown}
            onPointerLeave={() => setHoverIndex(null)}
            onKeyDown={handleKeyDown}
          />
        </div>
      </div>

      {/* Legend (account-type tiers). */}
      <ul className="flex flex-wrap items-center gap-x-4 gap-y-1.5">
        {model.layerKeys.map((key) => (
          <li
            key={key}
            className="flex items-center gap-1.5 text-xs text-[#64748B]"
          >
            <span
              aria-hidden="true"
              className="inline-block h-2.5 w-3 rounded-sm"
              style={{ backgroundColor: colorFor(key).solid }}
            />
            {ft(`forecasts.chart.segment.${key}`)}
          </li>
        ))}
      </ul>

      {/* Screen-reader data summary (one row per plotted year). */}
      <table className="sr-only" data-testid="forecast-chart-summary">
        <caption>
          {ft("forecasts.chart.summary_caption", {
            metric: ft(`forecasts.chart.plot.${mode.key}`),
          })}
        </caption>
        <thead>
          <tr>
            <th scope="col">{ft("forecasts.chart.summary_period")}</th>
            <th scope="col">{ft("forecasts.chart.summary_value")}</th>
          </tr>
        </thead>
        <tbody>
          {model.columns.map((column) => (
            <tr key={column.periodKey}>
              <th scope="row">{column.year}</th>
              <td className="privacy-sensitive">{fmt.full(column.total)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
