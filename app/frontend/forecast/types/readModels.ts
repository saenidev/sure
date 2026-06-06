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

// ---------------------------------------------------------------------------
// Forecast V2 first-viewport read models (slice C3).
//
// These interfaces type the REAL props `ForecastsController#show` serializes for
// the `Forecast/Workspace` Inertia page (assembled in slice C2 by
// `Forecasts::WorkspaceLoading#forecast_v2_workspace_props`). Each interface maps
// 1:1 to a Ruby read-model `#to_h` (B13), so the keys are the read models'
// snake_case keys exactly as Inertia serializes them — Inertia is NOT configured
// to camelize, so the wire shape is the Ruby hash shape. The only camelCase keys
// are the top-level region names the controller sets directly (`selectedPeriod`,
// `assumptionGroups`).
//
// Money is always a decimal string plus a currency context, never a JS float
// (matching the V2 projection-result contract). The server threads the run/as-of
// date, so these props are deterministic and the client renders the first
// viewport with zero network requests.
//
// Read-model boundary: these are presentation slices only. They never carry raw
// engine packets, full projection-result JSON, editor form values, or per-card /
// per-trace queries — those belong to later JSON endpoints and editor read
// models.
// ---------------------------------------------------------------------------

/**
 * The full projection-freshness lifecycle the `FreshnessIndicator` must cover.
 * `fresh | stale | recomputing | failed | superseded` are the
 * `Forecasts::ProjectionCache` statuses; `uncomputed` is emitted before the first
 * cache exists; `source-limited` is the source-limited remediation state from the
 * spec's component contract.
 */
export type FreshnessLifecycleState =
	| "fresh"
	| "stale"
	| "recomputing"
	| "failed"
	| "superseded"
	| "uncomputed"
	| "source-limited";

/**
 * The shell/region freshness facet shared by `PlanReadModel`,
 * `ProjectionBandReadModel`, and `SelectedPeriodReadModel` (`#freshness` and the
 * top-level `freshness` region). Pairs the lifecycle state with the ISO-8601
 * instant the projection was computed (`null` before the first projection).
 */
export interface ProjectionFreshness {
	readonly state: FreshnessLifecycleState;
	readonly projected_at: string | null;
}

/** The live scenario-stack summary on the plan shell (key + bounded layer keys). */
export interface ScenarioStackSummary {
	readonly key: string;
	readonly layers: readonly string[];
}

/** The privacy-mode facet the shell frames (ephemeral, client-owned truth). */
export interface PlanPrivacyState {
	readonly blurred: boolean;
}

/** Privacy-safe issue summary stored on the cache row (counts + codes only). */
export interface LatestIssueSummary {
	readonly status: string;
	readonly issue_count: number;
	readonly codes: Readonly<Record<string, number>>;
}

/**
 * `Forecasts::PlanReadModel#to_h` — answers "what plan is open and what shell
 * frames it?". Plan identity, lens nav, scenario-stack summary, freshness,
 * privacy, shell actions, and the latest issue summary. No chart series, no card
 * detail, no raw packets.
 */
export interface PlanReadModel {
	readonly id: string;
	readonly name: string;
	readonly reporting_currency: string;
	readonly plan_version: number;
	readonly active_lens: string;
	readonly lenses: readonly string[];
	readonly scenario_stack: ScenarioStackSummary;
	readonly freshness: ProjectionFreshness;
	readonly privacy: PlanPrivacyState;
	readonly actions: readonly string[];
	readonly latest_issue_summary: LatestIssueSummary;
}

/**
 * One compact chart point from `ProjectionBandReadModel#series`: a period key and
 * the selected metric's decimal-string value (`null` if absent for the period).
 */
export interface ProjectionBandPoint {
	readonly period_key: PeriodKey;
	readonly value: MoneyString | null;
}

/**
 * `Forecasts::ProjectionBandReadModel#to_h` — answers "what should the main chart
 * and selected-period control show?". The compact preloaded period index the
 * client scrubs locally (no network).
 */
export interface ProjectionBandReadModel {
	readonly selected_metric: string;
	readonly selected_marker: PeriodKey | null;
	readonly period_keys: readonly PeriodKey[];
	readonly series: readonly ProjectionBandPoint[];
	readonly freshness: ProjectionFreshness;
}

/**
 * One metric-strip entry from `SelectedPeriodReadModel#metrics`: a stable key, an
 * i18n `label_key` (the client localizes — the read model never formats UI
 * strings), and the period's value (decimal string for money, integer string for
 * runway, `null` when absent).
 */
export interface SelectedPeriodMetric {
	readonly key: string;
	readonly label_key: string;
	readonly value: MoneyString | null;
}

/** One trace-backed explanation line for the selected period. */
export interface SelectedPeriodExplanationLine {
	readonly kind: string;
	readonly amount: MoneyString | null;
	readonly currency: string | null;
	readonly direction: string | null;
	readonly explanation_key: string | null;
	readonly source: string;
}

/** One privacy-safe period issue line (code + severity + i18n message key). */
export interface SelectedPeriodIssueLine {
	readonly code: string;
	readonly severity: string;
	readonly message_key: string;
}

/**
 * `Forecasts::SelectedPeriodReadModel#to_h` — answers "what explains the
 * currently selected period?". Seeded for the default period; `null` before any
 * period is projected (the inspector opens on a "select a period" state).
 */
export interface SelectedPeriodReadModel {
	readonly period_key: PeriodKey;
	readonly granularity: string;
	readonly selected_metric: string;
	readonly metrics: readonly SelectedPeriodMetric[];
	readonly active_assumption_ids: readonly string[];
	readonly explanation: readonly SelectedPeriodExplanationLine[];
	readonly issues: readonly SelectedPeriodIssueLine[];
	readonly freshness: ProjectionFreshness;
}

/** A structured, client-formatted summary line on an assumption card. */
export interface AssumptionCardSummary {
	readonly key: string;
	readonly [field: string]: string | null | undefined;
}

/** Provenance/review badge code shown on an assumption card. */
export type AssumptionCardBadge =
	| "review_suggested"
	| "derived"
	| "low_confidence"
	| "disabled";

/** One assumption card from `AssumptionGroupReadModel` (scannable summary only). */
export interface AssumptionCard {
	readonly id: string;
	readonly kind: string;
	readonly icon: string;
	readonly title: string;
	readonly amount_summary: AssumptionCardSummary;
	readonly time_summary: AssumptionCardSummary;
	readonly behavior_summary: AssumptionCardSummary;
	readonly source_summary: AssumptionCardSummary;
	readonly status_badges: readonly string[];
	readonly active_in_period: boolean;
	readonly actions: readonly string[];
}

/** One assumption group (kind header + its cards). */
export interface AssumptionGroup {
	readonly kind: string;
	readonly title_key: string;
	readonly cards: readonly AssumptionCard[];
}

/**
 * `Forecasts::AssumptionGroupReadModel#to_h` — answers "which assumptions are
 * visible and scannable?".
 */
export interface AssumptionGroupReadModel {
	readonly groups: readonly AssumptionGroup[];
}

/**
 * `Forecasts::IssueReadModel#to_h` — one privacy-safe, user-facing plan/source
 * issue (no UUIDs, no debug context). The first-viewport `issues` region is an
 * array of these.
 */
export interface IssueReadModel {
	readonly code: string;
	readonly severity: string;
	readonly source: string;
	readonly period: string | null;
	readonly title: string | null;
	readonly affected_output: string | null;
	readonly impact: string | null;
	readonly message_key: string | null;
	readonly actions: readonly string[];
}

/**
 * The full typed first-viewport prop bag `ForecastsController#show` (V2) passes
 * to the `Forecast/Workspace` Inertia page. Each region is one read model.
 * `selectedPeriod` is `null` before any period is projected.
 */
export interface ForecastWorkspaceProps {
	readonly plan: PlanReadModel;
	readonly band: ProjectionBandReadModel;
	readonly selectedPeriod: SelectedPeriodReadModel | null;
	readonly assumptionGroups: AssumptionGroupReadModel;
	readonly issues: readonly IssueReadModel[];
	readonly freshness: ProjectionFreshness;
}
