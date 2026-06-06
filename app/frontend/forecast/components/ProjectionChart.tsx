// Forecast V2 ProjectionChart (slice C4).
//
// The real D3 projection chart on the `/forecast` Inertia workspace — the
// chart-rendering decision-gate prototype (spec "Chart Rendering Decision Gate",
// "Forecast Component Contracts" -> `ProjectionChart`: "chart container, metric
// controls, selected-period scrubber, chart summary table, and data payload
// attachment"). It is fed ENTIRELY by the preloaded `ProjectionBandReadModel`:
// pointer hover/scrub moves an EPHEMERAL local marker with ZERO network requests
// (spec "Chart scrubbing must be local"); a SETTLED selection — pointer down/click
// or a keyboard selection — is the only thing dispatched up through
// `useForecastWorkspace.selectPeriod` (the cache-fetch path).
//
// State ownership: chart math lives in `useProjectionChart`; this component owns
// only the DOM + presentation so D3 and React never fight over nodes. It reads
// the selected period from the shared workspace store and reports selection
// changes back to it — it never fetches, never persists, and never owns plan
// truth. Resize is handled via the hook's container ref + stable viewBox so the
// band never clips or overlaps. A reduced-motion-respecting marker transition and
// a screen-reader data-summary table fallback round out the gate requirements.
//
// Tokens only: Sure semantic classes plus `var(--color-*)` for SVG stroke/fill
// attributes that cannot take a utility class. No raw palette hexes, no
// lucide_icon. User-facing copy resolves through the client i18n table (`ft`).

import type { JSX } from "react";
import {
	type ProjectionChartSummaryRow,
	useProjectionChart,
} from "../hooks/useProjectionChart";
import { ft } from "../i18n";
import type { ProjectionBandReadModel } from "../types/readModels";

// Format a canonical decimal-string value for display. The canonical string stays
// the source of truth; this only renders it. Returns an em dash for absent values.
function formatValue(value: string | null): string {
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

// The screen-reader data-summary table: a real <table> mirroring every plotted
// period so assistive tech reads the same data the marker shows. Visually hidden
// (sr-only) but in the accessibility tree (the gate's "data summary fallback").
function DataSummaryTable({
	rows,
	metricLabel,
}: {
	readonly rows: readonly ProjectionChartSummaryRow[];
	readonly metricLabel: string;
}): JSX.Element {
	return (
		<table className="sr-only" data-testid="forecast-chart-summary">
			<caption>
				{ft("forecasts.chart.summary_caption", { metric: metricLabel })}
			</caption>
			<thead>
				<tr>
					<th scope="col">{ft("forecasts.chart.summary_period")}</th>
					<th scope="col">{ft("forecasts.chart.summary_value")}</th>
				</tr>
			</thead>
			<tbody>
				{rows.map((row) => (
					<tr key={row.periodKey}>
						<th scope="row">{row.periodKey}</th>
						<td>{formatValue(row.value)}</td>
					</tr>
				))}
			</tbody>
		</table>
	);
}

export interface ProjectionChartProps {
	/** The preloaded projection band (compact period index + selected metric). */
	readonly band: ProjectionBandReadModel;
	/** The selected period from the shared store (drives the marker). */
	readonly selectedPeriodKey: string | null;
	/** Reports a settled, locally-resolved selection up to the workspace store. */
	readonly onSelectPeriod: (periodKey: string) => void;
	/** Stable region id for scoped patches / tests. */
	readonly regionKey?: string;
	/** Stable cache key (plan version + scenario stack) for scoped patches. */
	readonly cacheKey?: string;
}

export default function ProjectionChart({
	band,
	selectedPeriodKey,
	onSelectPeriod,
	regionKey = "forecast-projection-chart",
	cacheKey,
}: ProjectionChartProps): JSX.Element {
	const chart = useProjectionChart({
		periodKeys: band.period_keys,
		series: band.series,
		selectedPeriodKey,
		onSelectPeriod,
	});

	// A human-ish metric label for the summary caption: the read model carries a
	// metric KEY (e.g. "net_worth"); reuse the client copy table when present.
	const metricLabel = ft(`forecasts.metrics.${band.selected_metric}`);

	if (!chart.hasData) {
		return (
			<section
				data-testid={regionKey}
				data-region={regionKey}
				data-cache-key={cacheKey}
				className="rounded-xl border border-primary bg-container p-6 text-sm text-subdued"
			>
				{ft("forecasts.chart.empty")}
			</section>
		);
	}

	const selectedValue = chart.selectedPoint
		? formatValue(chart.selectedPoint.value)
		: "—";
	const selectedPeriod = chart.selectedPeriodKey ?? band.selected_marker ?? "—";

	// Reduced-motion: no transition. Otherwise a quick marker ease.
	const markerTransition = chart.reducedMotion
		? "none"
		: "cx 120ms ease-out, cy 120ms ease-out";

	const maxIndex = Math.max(0, chart.points.length - 1);
	const selectedValueIndex = chart.selectedPoint?.index ?? 0;

	return (
		<section
			data-testid={regionKey}
			data-region={regionKey}
			data-cache-key={cacheKey}
			data-selected-metric={band.selected_metric}
			aria-label={ft("forecasts.chart.label")}
			className="flex flex-col gap-3 rounded-xl border border-primary bg-container p-4 sm:p-5"
		>
			<header className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
				<h2 className="text-sm font-medium text-primary">
					{ft("forecasts.chart.label")}
				</h2>
				<dl className="flex min-w-0 items-baseline gap-2">
					<dt className="shrink-0 text-xs text-subdued">{selectedPeriod}</dt>
					<dd
						data-testid="forecast-chart-value"
						className="privacy-sensitive truncate text-base font-semibold tabular-nums text-primary"
					>
						{selectedValue}
					</dd>
				</dl>
			</header>

			{/* The focusable scrubber region owns focus + keyboard + pointer
			    interaction so the role lives on an interactive element; the SVG inside
			    is purely presentational. The stable viewBox keeps the D3 math
			    anchor-deterministic while the box scales to its container (no
			    clipping / overlap on resize). Pointer movement moves the local hover
			    marker; a press / arrow keys SETTLE the selection — hover/scrub is
			    ZERO network. */}
			<div
				ref={chart.containerRef}
				data-testid="forecast-chart-scrubber"
				role="slider"
				tabIndex={0}
				aria-label={ft("forecasts.chart.scrubber_label")}
				aria-valuemin={0}
				aria-valuemax={maxIndex}
				aria-valuenow={selectedValueIndex}
				aria-valuetext={ft("forecasts.chart.selected_period", {
					period: selectedPeriod,
					value: selectedValue,
				})}
				className="h-44 w-full touch-none rounded-lg border border-primary bg-surface-inset outline-none focus-visible:ring-2 focus-visible:ring-gray-400 sm:h-56"
				onPointerMove={chart.handlePointerMove}
				onPointerDown={chart.handlePointerDown}
				onKeyDown={chart.handleKeyDown}
			>
				<svg
					data-testid="forecast-chart-svg"
					aria-hidden="true"
					viewBox={`0 0 ${chart.viewBox.width} ${chart.viewBox.height}`}
					preserveAspectRatio="none"
					className="h-full w-full"
				>
					<path
						d={chart.linePath}
						fill="none"
						stroke="var(--color-gray-500)"
						strokeWidth={2}
						strokeLinecap="round"
						strokeLinejoin="round"
					/>
					{chart.selectedPoint && chart.selectedPoint.cy !== null ? (
						<g>
							<line
								x1={chart.selectedPoint.cx}
								x2={chart.selectedPoint.cx}
								y1={chart.margin.top}
								y2={chart.viewBox.height - chart.margin.bottom}
								stroke="var(--color-gray-400)"
								strokeDasharray="3 3"
							/>
							<circle
								data-testid="forecast-chart-marker"
								cx={chart.selectedPoint.cx}
								cy={chart.selectedPoint.cy}
								r={5}
								fill="var(--color-white)"
								stroke="var(--color-gray-700)"
								strokeWidth={2}
								style={{ transition: markerTransition }}
							/>
						</g>
					) : null}
				</svg>
			</div>

			{/* Live region announcing the selected period for screen readers, mirroring
			    the marker so assistive tech stays in sync as it scrubs. */}
			<p className="sr-only" aria-live="polite">
				{ft("forecasts.chart.selected_period", {
					period: selectedPeriod,
					value: selectedValue,
				})}
			</p>

			{/* The screen-reader data-summary table fallback (decision-gate requirement). */}
			<DataSummaryTable rows={chart.summaryRows} metricLabel={metricLabel} />
		</section>
	);
}
