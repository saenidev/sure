// Forecast V2 projection-chart interaction module (slice C4).
//
// `useProjectionChart` is the ONE focused module for the projection-chart
// interaction region (spec "Frontend Runtime Modules" -> `useProjectionChart`:
// "renders the chart, handles resize, metric selection, hover, drag/scrub,
// keyboard period selection, and local marker movement"). It owns chart MATH
// only — D3 scales + line path from the preloaded `ProjectionBandReadModel`
// series, the responsive size, pointer/keyboard selection, reduced-motion, and
// the screen-reader data-summary rows. The React component (`ProjectionChart`)
// owns the DOM so the two never fight over the same nodes.
//
// Pointer hover/scrub and keyboard period selection are PURELY LOCAL: they walk
// the compact preloaded period index and issue ZERO network requests (spec
// "Chart scrubbing must be local"). A settled selection is reported up through
// the shared workspace store via `onSelectPeriod`; this module never fetches,
// never persists, and never parses engine result internals — the server owns
// canonical plan truth. Keep it chart math only (no persistence).

import { line, scaleLinear, scalePoint } from "d3";
import {
	type KeyboardEvent,
	type PointerEvent,
	useCallback,
	useEffect,
	useLayoutEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import type { PeriodKey, ProjectionBandPoint } from "../types/readModels";

// The fixed internal viewBox the SVG draws into. The element scales responsively
// to its container width while keeping these coordinates stable, so the D3 math
// stays anchor-deterministic regardless of rendered pixel size (no clipping, no
// text overlap — the chrome lives outside the plotted band).
const VIEW_WIDTH = 720;
const VIEW_HEIGHT = 240;
const MARGIN = { top: 16, right: 16, bottom: 16, left: 16 } as const;

/** One plotted point: its series index, period key, screen coords, and value. */
export interface ProjectionChartPoint {
	readonly index: number;
	readonly periodKey: PeriodKey;
	/** X in viewBox units. */
	readonly cx: number;
	/** Y in viewBox units; null when the period has no value (gap in the line). */
	readonly cy: number | null;
	/** The canonical decimal-string value for the period; null when absent. */
	readonly value: string | null;
}

/** A screen-reader data-summary row mirroring one plotted period. */
export interface ProjectionChartSummaryRow {
	readonly periodKey: PeriodKey;
	readonly value: string | null;
}

export interface UseProjectionChartArgs {
	/** Chronologically ordered period keys (the keyboard axis the marker walks). */
	readonly periodKeys: readonly PeriodKey[];
	/** Compact, chart-ready band series (one point per period, value may be null). */
	readonly series: readonly ProjectionBandPoint[];
	/** The currently selected period from the shared store (drives the marker). */
	readonly selectedPeriodKey: PeriodKey | null;
	/** Reports a settled, locally-resolved selection up to the workspace store. */
	readonly onSelectPeriod: (periodKey: PeriodKey) => void;
}

export interface UseProjectionChartResult {
	/** Internal viewBox dimensions + margins for the SVG the component renders. */
	readonly viewBox: { readonly width: number; readonly height: number };
	readonly margin: typeof MARGIN;
	/** The SVG path `d` for the projection line (gaps split it into segments). */
	readonly linePath: string;
	/** Every plotted point (for the data summary + marker positioning). */
	readonly points: readonly ProjectionChartPoint[];
	/** The point the marker sits on, or null when nothing is selected/plottable. */
	readonly selectedPoint: ProjectionChartPoint | null;
	/** The period key the marker tracks (mirrors the store, clamped to range). */
	readonly selectedPeriodKey: PeriodKey | null;
	/** Whether the chart has any plottable point at all. */
	readonly hasData: boolean;
	/** True when the user asked for reduced motion (drops the marker transition). */
	readonly reducedMotion: boolean;
	/** Screen-reader data-summary rows mirroring the plotted series. */
	readonly summaryRows: readonly ProjectionChartSummaryRow[];
	/** Ref to attach to the responsive container (drives resize tracking). */
	readonly containerRef: React.RefObject<HTMLDivElement | null>;
	/** Pointer-move handler: selects the nearest period locally (no network). */
	readonly handlePointerMove: (event: PointerEvent<HTMLDivElement>) => void;
	/** Pointer-down handler: settles selection on the nearest period. */
	readonly handlePointerDown: (event: PointerEvent<HTMLDivElement>) => void;
	/** Keyboard handler: arrows/Home/End move the selected period (no network). */
	readonly handleKeyDown: (event: KeyboardEvent<HTMLDivElement>) => void;
}

// Detect reduced-motion once; false in SSR/non-browser so server + first client
// paint agree. (Listening for changes is unnecessary for this prototype gate.)
function detectReducedMotion(): boolean {
	if (typeof window === "undefined" || !window.matchMedia) {
		return false;
	}
	return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export function useProjectionChart({
	periodKeys,
	series,
	selectedPeriodKey,
	onSelectPeriod,
}: UseProjectionChartArgs): UseProjectionChartResult {
	const containerRef = useRef<HTMLDivElement | null>(null);
	const [reducedMotion, setReducedMotion] = useState(false);

	// Resolve reduced motion after mount so the first paint is deterministic.
	useEffect(() => {
		setReducedMotion(detectReducedMotion());
	}, []);

	// Observe the container so resize never clips the band: the SVG uses a stable
	// viewBox and scales to the box, but tracking width lets the component pick a
	// non-overlapping label cadence. We only store width to avoid re-render storms.
	const [containerWidth, setContainerWidth] = useState(0);
	useLayoutEffect(() => {
		const node = containerRef.current;
		if (!node || typeof ResizeObserver === "undefined") {
			return;
		}
		const observer = new ResizeObserver((entries) => {
			for (const entry of entries) {
				setContainerWidth(entry.contentRect.width);
			}
		});
		observer.observe(node);
		setContainerWidth(node.getBoundingClientRect().width);
		return () => observer.disconnect();
	}, []);

	// D3 owns the math: a point scale over period index for X and a linear value
	// scale for Y, plus a line generator. Memoized so the path/scales only
	// recompute when the preloaded band changes — NEVER during pointer movement.
	const { points, linePath, xOf } = useMemo(() => {
		const innerWidth = VIEW_WIDTH - MARGIN.left - MARGIN.right;
		const innerHeight = VIEW_HEIGHT - MARGIN.top - MARGIN.bottom;

		const x = scalePoint<number>()
			.domain(series.map((_, index) => index))
			.range([MARGIN.left, MARGIN.left + innerWidth]);

		const numericValues = series
			.map((point) =>
				point.value === null ? null : Number.parseFloat(point.value),
			)
			.filter(
				(value): value is number => value !== null && !Number.isNaN(value),
			);

		const minValue = numericValues.length > 0 ? Math.min(...numericValues) : 0;
		const maxValue = numericValues.length > 0 ? Math.max(...numericValues) : 1;
		const y = scaleLinear()
			.domain(
				minValue === maxValue
					? [minValue - 1, maxValue + 1]
					: [minValue, maxValue],
			)
			.range([MARGIN.top + innerHeight, MARGIN.top])
			.nice();

		const computed: ProjectionChartPoint[] = series.map((point, index) => {
			const numeric =
				point.value === null ? null : Number.parseFloat(point.value);
			const cy = numeric === null || Number.isNaN(numeric) ? null : y(numeric);
			return {
				index,
				periodKey: point.period_key,
				cx: x(index) ?? MARGIN.left,
				cy,
				value: point.value,
			};
		});

		// Build the line over only plottable points; null values break the path
		// into segments (defined()) so gaps do not draw a misleading straight line.
		const generator = line<ProjectionChartPoint>()
			.defined((d) => d.cy !== null)
			.x((d) => d.cx)
			.y((d) => d.cy ?? 0);

		return {
			points: computed,
			linePath: generator(computed) ?? "",
			xOf: (index: number) => x(index) ?? MARGIN.left,
		};
	}, [series]);

	const hasData = points.some((point) => point.cy !== null);

	// The marker tracks the store's selected period, clamped into range; falls
	// back to the first plottable point so the chart always shows a marker when it
	// has data. Resolution is index-based off the preloaded period axis.
	const selectedIndex = useMemo(() => {
		if (selectedPeriodKey !== null) {
			const found = periodKeys.indexOf(selectedPeriodKey);
			if (found >= 0) {
				return found;
			}
		}
		const firstPlottable = points.findIndex((point) => point.cy !== null);
		return firstPlottable >= 0 ? firstPlottable : -1;
	}, [selectedPeriodKey, periodKeys, points]);

	const selectedPoint =
		selectedIndex >= 0 ? (points[selectedIndex] ?? null) : null;
	const resolvedSelectedKey = selectedPoint?.periodKey ?? selectedPeriodKey;

	// Map a viewBox X to the nearest period index by X distance — purely on the
	// preloaded scale (NO fetch, NO Inertia visit). This is the no-network proof.
	const nearestIndexToViewX = useCallback(
		(viewX: number): number => {
			let nearest = -1;
			let nearestDistance = Number.POSITIVE_INFINITY;
			for (const point of points) {
				const distance = Math.abs(xOf(point.index) - viewX);
				if (distance < nearestDistance) {
					nearestDistance = distance;
					nearest = point.index;
				}
			}
			return nearest;
		},
		[points, xOf],
	);

	const selectNearestFromClientX = useCallback(
		(clientX: number, target: HTMLDivElement): void => {
			const rect = target.getBoundingClientRect();
			if (rect.width === 0) {
				return;
			}
			const ratio = (clientX - rect.left) / rect.width;
			const viewX = ratio * VIEW_WIDTH;
			const nearest = nearestIndexToViewX(viewX);
			const point = nearest >= 0 ? points[nearest] : undefined;
			if (point) {
				onSelectPeriod(point.periodKey);
			}
		},
		[nearestIndexToViewX, points, onSelectPeriod],
	);

	const handlePointerMove = useCallback(
		(event: PointerEvent<HTMLDivElement>): void => {
			// Only scrub while a button is held (drag) OR a pen/touch contact moves.
			// A bare mouse hover also scrubs the marker; either way it is local-only.
			selectNearestFromClientX(event.clientX, event.currentTarget);
		},
		[selectNearestFromClientX],
	);

	const handlePointerDown = useCallback(
		(event: PointerEvent<HTMLDivElement>): void => {
			selectNearestFromClientX(event.clientX, event.currentTarget);
		},
		[selectNearestFromClientX],
	);

	const handleKeyDown = useCallback(
		(event: KeyboardEvent<HTMLDivElement>): void => {
			if (points.length === 0) {
				return;
			}
			const current = selectedIndex >= 0 ? selectedIndex : 0;
			const clamp = (index: number) =>
				Math.min(points.length - 1, Math.max(0, index));
			let next: number | null = null;
			if (event.key === "ArrowRight" || event.key === "ArrowUp") {
				next = clamp(current + 1);
			} else if (event.key === "ArrowLeft" || event.key === "ArrowDown") {
				next = clamp(current - 1);
			} else if (event.key === "Home") {
				next = 0;
			} else if (event.key === "End") {
				next = points.length - 1;
			}
			if (next !== null) {
				event.preventDefault();
				const point = points[next];
				if (point) {
					onSelectPeriod(point.periodKey);
				}
			}
		},
		[points, selectedIndex, onSelectPeriod],
	);

	const summaryRows = useMemo<ProjectionChartSummaryRow[]>(
		() =>
			points.map((point) => ({
				periodKey: point.periodKey,
				value: point.value,
			})),
		[points],
	);

	// `containerWidth` participates only to keep the resize observation live; the
	// viewBox math is width-independent. Referencing it here documents that intent
	// without forcing the chart to recompute scales on every resize tick.
	void containerWidth;

	return {
		viewBox: { width: VIEW_WIDTH, height: VIEW_HEIGHT },
		margin: MARGIN,
		linePath,
		points,
		selectedPoint,
		selectedPeriodKey: resolvedSelectedKey,
		hasData,
		reducedMotion,
		summaryRows,
		containerRef,
		handlePointerMove,
		handlePointerDown,
		handleKeyDown,
	};
}
