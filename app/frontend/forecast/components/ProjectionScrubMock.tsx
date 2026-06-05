// Forecast V2 local D3 scrub mock (spike slice A5).
//
// The core viability proof for the Inertia path: a tiny D3-driven SVG chart fed
// ENTIRELY by the preloaded period/metric props. Pointer movement over the chart
// updates the active marker and the selected metric value purely client-side —
// ZERO network requests during pointer movement (per the spec "Chart scrubbing
// must be local"). Arrow keys move the selected period (keyboard period
// selection). It respects `prefers-reduced-motion` by dropping the marker
// transition when the user asks for reduced motion.
//
// D3 owns only the chart MATH (scales + line path generation); React owns the
// DOM so the two never fight over the same nodes. This module owns exactly one
// interaction region (the scrub chart) and seeds its selection from
// `currentPeriodKey`; the server still owns canonical plan truth.
//
// Tokens only: Sure semantic classes (text-primary, bg-container, border
// border-primary, ...) plus `var(--color-*)` for the SVG stroke/fill attributes
// that cannot take a utility class. No raw palette hexes, no lucide_icon.

import { line, scaleLinear, scalePoint } from "d3";
import {
	type JSX,
	type KeyboardEvent,
	type PointerEvent,
	useId,
	useMemo,
	useState,
} from "react";
import type { MetricSeriesPoint, PeriodKey } from "../types/readModels";

// The fixed viewBox the SVG draws into. The element scales responsively to its
// container width while keeping these internal coordinates stable, so the D3
// math stays anchor-deterministic regardless of rendered pixel size.
const VIEW_WIDTH = 720;
const VIEW_HEIGHT = 220;
const MARGIN = { top: 16, right: 16, bottom: 16, left: 16 } as const;

// Which preloaded metric the marker reads off the series points.
type MetricKey = "netWorth" | "cash";

export interface ProjectionScrubMockProps {
	/** Chronologically ordered period keys; the keyboard axis the marker walks. */
	readonly periodKeys: readonly PeriodKey[];
	/** Compact, chart-ready metric series (one point per period). */
	readonly series: readonly MetricSeriesPoint[];
	/** The period the marker starts on (server-seeded). */
	readonly currentPeriodKey: PeriodKey;
	/** ISO-4217 currency context for the displayed metric value. */
	readonly currency: string;
	/** Which metric the chart line + marker track. Defaults to net worth. */
	readonly metric?: MetricKey;
}

// Detect the user's reduced-motion preference once on mount. Returns false in
// non-browser/SSR contexts so the server render and first client paint agree.
function prefersReducedMotion(): boolean {
	if (typeof window === "undefined" || !window.matchMedia) {
		return false;
	}
	return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// Format a decimal-string money amount for display without floats taking over
// the canonical value. Throwaway spike formatting; Stage C localizes currency.
function formatMoney(value: string, currency: string): string {
	const parsed = Number.parseFloat(value);
	if (Number.isNaN(parsed)) {
		return `${value} ${currency}`;
	}
	try {
		return new Intl.NumberFormat(undefined, {
			style: "currency",
			currency,
			maximumFractionDigits: 0,
		}).format(parsed);
	} catch {
		return `${value} ${currency}`;
	}
}

export default function ProjectionScrubMock({
	periodKeys,
	series,
	currentPeriodKey,
	currency,
	metric = "netWorth",
}: ProjectionScrubMockProps): JSX.Element {
	const titleId = useId();
	const reducedMotion = useMemo(prefersReducedMotion, []);

	// Seed selection from the server-provided current period; fall back to 0.
	const initialIndex = Math.max(0, periodKeys.indexOf(currentPeriodKey));
	const [selectedIndex, setSelectedIndex] = useState(initialIndex);

	// D3 owns the math: a point scale over period index for X and a linear value
	// scale for Y, plus a line generator. Memoized so the path/scales only
	// recompute when the preloaded data changes (never during pointer movement).
	const { points, linePath, xOf, clampIndex } = useMemo(() => {
		const innerWidth = VIEW_WIDTH - MARGIN.left - MARGIN.right;
		const innerHeight = VIEW_HEIGHT - MARGIN.top - MARGIN.bottom;
		const values = series.map((point) => Number.parseFloat(point[metric]));

		const x = scalePoint<number>()
			.domain(series.map((_, index) => index))
			.range([MARGIN.left, MARGIN.left + innerWidth]);
		const minValue = Math.min(...values);
		const maxValue = Math.max(...values);
		const y = scaleLinear()
			.domain(
				minValue === maxValue
					? [minValue - 1, maxValue + 1]
					: [minValue, maxValue],
			)
			.range([MARGIN.top + innerHeight, MARGIN.top])
			.nice();

		const computed = series.map((_, index) => ({
			index,
			cx: x(index) ?? MARGIN.left,
			cy: y(values[index]),
		}));

		const generator = line<{ cx: number; cy: number }>()
			.x((d) => d.cx)
			.y((d) => d.cy);

		return {
			points: computed,
			linePath: generator(computed) ?? "",
			xOf: (index: number) => x(index) ?? MARGIN.left,
			clampIndex: (index: number) =>
				Math.min(series.length - 1, Math.max(0, index)),
		};
	}, [series, metric]);

	const selectedPoint = points[selectedIndex] ?? points[0];
	const selectedSeries: MetricSeriesPoint | undefined = series[selectedIndex];

	// Map a pointer position to the nearest period by X distance. Runs purely on
	// the preloaded scale — NO fetch, NO Inertia visit. This is the no-network
	// proof asserted by system test A7.
	function selectNearest(clientX: number, target: HTMLDivElement): void {
		const rect = target.getBoundingClientRect();
		if (rect.width === 0) {
			return;
		}
		const ratio = (clientX - rect.left) / rect.width;
		const viewX = ratio * VIEW_WIDTH;
		let nearest = 0;
		let nearestDistance = Number.POSITIVE_INFINITY;
		for (const point of points) {
			const distance = Math.abs(xOf(point.index) - viewX);
			if (distance < nearestDistance) {
				nearestDistance = distance;
				nearest = point.index;
			}
		}
		setSelectedIndex(nearest);
	}

	function handlePointerMove(event: PointerEvent<HTMLDivElement>): void {
		selectNearest(event.clientX, event.currentTarget);
	}

	function handleKeyDown(event: KeyboardEvent<HTMLDivElement>): void {
		let next: number | null = null;
		if (event.key === "ArrowRight" || event.key === "ArrowUp") {
			next = clampIndex(selectedIndex + 1);
		} else if (event.key === "ArrowLeft" || event.key === "ArrowDown") {
			next = clampIndex(selectedIndex - 1);
		} else if (event.key === "Home") {
			next = 0;
		} else if (event.key === "End") {
			next = series.length - 1;
		}
		if (next !== null) {
			event.preventDefault();
			setSelectedIndex(next);
		}
	}

	const selectedPeriodKey = periodKeys[selectedIndex] ?? currentPeriodKey;
	const selectedValue = selectedSeries
		? formatMoney(selectedSeries[metric], currency)
		: "—";
	// Reduced-motion: no transition. Otherwise a quick marker ease.
	const markerTransition = reducedMotion
		? "none"
		: "cx 120ms ease-out, cy 120ms ease-out";

	return (
		<section
			data-testid="forecast-scrub-mock"
			aria-labelledby={titleId}
			className="flex flex-col gap-3 rounded-xl border border-primary bg-container p-4 sm:p-5"
		>
			<header className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
				<h2 id={titleId} className="text-sm font-medium text-primary">
					Projection scrub
				</h2>
				<dl className="flex min-w-0 items-baseline gap-2">
					<dt className="shrink-0 text-xs text-subdued">{selectedPeriodKey}</dt>
					<dd
						data-testid="forecast-scrub-value"
						className="truncate text-base font-semibold tabular-nums text-primary"
					>
						{selectedValue}
					</dd>
				</dl>
			</header>

			{/* The focusable slider region. The wrapping div owns focus + keyboard +
			    pointer interaction so the role lives on an interactive element; the
			    SVG inside is purely presentational. The viewBox keeps the D3 math
			    stable while the box scales to its container. Pointer movement and
			    arrow keys re-select with zero network. */}
			<div
				data-testid="forecast-scrub-region"
				role="slider"
				tabIndex={0}
				aria-labelledby={titleId}
				aria-valuemin={0}
				aria-valuemax={Math.max(0, series.length - 1)}
				aria-valuenow={selectedIndex}
				aria-valuetext={`${selectedPeriodKey}: ${selectedValue}`}
				className="h-40 w-full touch-none rounded-lg border border-primary bg-surface-inset outline-none focus-visible:ring-2 focus-visible:ring-gray-400 sm:h-48"
				onPointerMove={handlePointerMove}
				onKeyDown={handleKeyDown}
			>
				<svg
					data-testid="forecast-scrub-svg"
					aria-hidden="true"
					viewBox={`0 0 ${VIEW_WIDTH} ${VIEW_HEIGHT}`}
					preserveAspectRatio="none"
					className="h-full w-full"
				>
					<path
						d={linePath}
						fill="none"
						stroke="var(--color-gray-500)"
						strokeWidth={2}
						strokeLinecap="round"
						strokeLinejoin="round"
					/>
					{selectedPoint ? (
						<g>
							<line
								x1={selectedPoint.cx}
								x2={selectedPoint.cx}
								y1={MARGIN.top}
								y2={VIEW_HEIGHT - MARGIN.bottom}
								stroke="var(--color-gray-400)"
								strokeDasharray="3 3"
							/>
							<circle
								data-testid="forecast-scrub-marker"
								cx={selectedPoint.cx}
								cy={selectedPoint.cy}
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

			{/* Screen-reader data summary fallback, hidden visually. Mirrors the
			    selected period so assistive tech reads the same value the marker shows. */}
			<p className="sr-only" aria-live="polite">
				Selected period {selectedPeriodKey}, value {selectedValue}.
			</p>
		</section>
	);
}
