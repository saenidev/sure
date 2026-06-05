// Forecast V2 read-model prop types (spike slice A4).
//
// These TypeScript interfaces type the props that
// `ForecastV2SpikeController#show` serializes for the `Forecast/Spike` Inertia
// page. They are intentionally shaped to PREFIGURE the Stage C read-model
// contracts in the Forecast V2 design spec ("Read Model Contracts"):
//
//   - `PlanLabel`        -> a slice of `PlanReadModel` (what plan is open).
//   - `PeriodKey` /
//     `MetricSeriesPoint` -> a slice of `ProjectionBandReadModel`
//                            (what the chart + selected-period control shows).
//   - `FreshnessState`   -> the projection-freshness facet shared by
//                            `PlanReadModel` / `SelectedPeriodReadModel` and
//                            rendered by the `FreshnessIndicator` component.
//
// Money is always a decimal string plus an enclosing currency context, never a
// JS float, matching the V2 projection-result contract. The run/as-of date is
// threaded in by the server, so these props are deterministic for a given
// anchor and the client renders them with zero network requests.

/**
 * A month period key in `YYYY-MM` form (e.g. `"2026-06"`). Period keys are the
 * stable identity the chart, scrubber, and selected-period control share. They
 * are always chronologically ordered in a series.
 */
export type PeriodKey = string;

/**
 * A monetary amount as a decimal string (e.g. `"108420.00"`). Never a float;
 * the enclosing read model carries the ISO-4217 currency context separately
 * (see {@link PlanLabel.currency}).
 */
export type MoneyString = string;

/**
 * The plan-identity facet of the eventual `PlanReadModel`: enough to label the
 * open plan and frame the workspace shell. Excludes chart series, assumption
 * card details, and raw engine packets (per the read-model contract).
 */
export interface PlanLabel {
	/** Stable plan identifier (opaque to the client). */
	readonly id: string;
	/** User-facing, localized plan label rendered in the shell header. */
	readonly label: string;
	/** ISO-4217 currency code that contextualizes every {@link MoneyString}. */
	readonly currency: string;
	/** Monotonic plan version; bumps drive scoped recompute/patch in Stage C. */
	readonly version: number;
}

/**
 * One point of the projection band: a single period's compact, chart-ready
 * metrics. Part of the eventual `ProjectionBandReadModel`. The client scrubs an
 * ordered array of these locally (no network) to drive the selected marker and
 * metric strip.
 */
export interface MetricSeriesPoint {
	/** The period this point belongs to; matches an entry in `periodKeys`. */
	readonly periodKey: PeriodKey;
	/** Projected net worth for the period, as a decimal string. */
	readonly netWorth: MoneyString;
	/** Projected cash position for the period, as a decimal string. */
	readonly cash: MoneyString;
}

/**
 * Projection freshness lifecycle, rendered by the `FreshnessIndicator`
 * component. The full set prefigures every state the Stage C indicator must
 * cover (`PlanReadModel` / `SelectedPeriodReadModel` freshness facet); the
 * spike only emits the first three.
 */
export type FreshnessLifecycle =
	| "fresh"
	| "stale"
	| "recomputing"
	| "failed"
	| "source-limited";

/**
 * The freshness facet shared by the plan- and selected-period read models.
 * Pairs the lifecycle {@link FreshnessLifecycle} state with the timestamp the
 * current projection was computed at (ISO-8601), so the indicator can show both
 * the status and "as of" context.
 */
export interface FreshnessState {
	/** Where this projection sits in the recompute lifecycle. */
	readonly state: FreshnessLifecycle;
	/** ISO-8601 instant the current projection was computed (server-threaded). */
	readonly projectedAt: string;
}

/**
 * A first-viewport metric-strip entry: one labeled metric value for the
 * currently selected period. Part of the eventual `SelectedPeriodReadModel`
 * metric strip.
 */
export interface MetricStripEntry {
	/** Stable metric key (e.g. `"net_worth"`, `"cash"`). */
	readonly key: string;
	/** User-facing, localized metric label. */
	readonly label: string;
	/** The metric's value for the selected period, as a decimal string. */
	readonly value: MoneyString;
}

/**
 * Client-seeded privacy state. Privacy mode in Sure is a client-side
 * (localStorage) preference; the server seeds the default and the client
 * hydrates from its own source of truth.
 */
export interface PrivacyState {
	readonly enabled: boolean;
}

/**
 * The full typed prop bag the `ForecastV2SpikeController` passes to the
 * `Forecast/Spike` Inertia page. Each field maps 1:1 to a serialized controller
 * prop and is composed from the read-model-shaped types above.
 */
export interface ForecastSpikeProps {
	readonly plan: PlanLabel;
	readonly currentPeriodKey: PeriodKey;
	readonly periodKeys: readonly PeriodKey[];
	readonly series: readonly MetricSeriesPoint[];
	readonly metrics: readonly MetricStripEntry[];
	readonly privacy: PrivacyState;
	readonly freshness: FreshnessState;
}
