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
 *
 * `series` is the selected metric's compact series (first paint); `metric_series`
 * carries every chartable metric's series so the metric selector re-points the
 * chart LOCALLY with zero network. `available_metrics` is the ordered set of
 * metric keys the selector offers (each resolves to `forecasts.metrics.<key>`).
 */
export interface ProjectionBandReadModel {
	readonly selected_metric: string;
	readonly selected_marker: PeriodKey | null;
	readonly available_metrics: readonly string[];
	readonly period_keys: readonly PeriodKey[];
	readonly series: readonly ProjectionBandPoint[];
	readonly metric_series: Readonly<Record<string, readonly ProjectionBandPoint[]>>;
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

// ---------------------------------------------------------------------------
// Forecast V2 editor-prefill read model (slice C7).
//
// These interfaces type the payload `Forecasts::AssumptionsController#edit`
// (GET /forecast/assumptions/:id/edit) serializes from
// `Forecasts::EditorPrefillReadModel#to_h` (B13). They answer exactly ONE UI
// question — "what does one typed editor need to open?" — and carry the form key,
// current values, collapsed-section summaries, and validation metadata
// (`lock_version` for stale-edit detection), and nothing else (no other
// assumptions, chart series, or projection-result bodies).
//
// The keys are the read model's snake_case keys exactly as Inertia/JSON
// serializes them (no camelization), matching every other Forecast V2 payload.
// ---------------------------------------------------------------------------

/**
 * The current editable values for the typed form's primary fields. Money stays a
 * decimal string; `params` rides through as the typed form's raw param inputs the
 * salary form reads (`person_key`, `gross_or_net`, `frequency`, `growth_policy`,
 * `growth_rate`, …). Extra fields are allowed (an index signature) because the
 * exact param set is form-specific.
 */
export interface EditorPrimaryValues {
	readonly name: string | null;
	readonly amount: MoneyString | null;
	readonly currency: string | null;
	readonly starts_on: string | null;
	readonly ends_on: string | null;
	readonly params: Readonly<Record<string, unknown>>;
}

/** One collapsed-section summary: an i18n `key` plus raw, client-formatted fields. */
export interface EditorSectionSummary {
	readonly key: string;
	readonly [field: string]: string | number | null | undefined;
}

/** The collapsed-section summaries shown before the user expands each section. */
export interface EditorSectionSummaries {
	readonly time_range: EditorSectionSummary;
	readonly change_over_time: EditorSectionSummary;
	readonly source: EditorSectionSummary;
}

/**
 * Validation metadata: the optimistic `lock_version` for stale-edit detection
 * plus the editor schema version. No projection bodies, no other records.
 */
export interface EditorValidationMeta {
	readonly lock_version: number;
	readonly schema_version: number;
}

/**
 * `Forecasts::EditorPrefillReadModel#to_h` — answers "what does one typed editor
 * need to open?". The typed editor-drawer payload for ONE assumption.
 */
export interface EditorPrefillReadModel {
	/** The form schema key (e.g. `"salary"`); selects the type-specific form. */
	readonly form_key: string;
	/** The assumption being edited (opaque id; family-resolved server-side). */
	readonly assumption_id: string;
	/** The scenario layer the edit targets, or `null` for the baseline plan. */
	readonly scenario_layer_id: string | null;
	readonly primary_values: EditorPrimaryValues;
	readonly section_summaries: EditorSectionSummaries;
	readonly validation: EditorValidationMeta;
}

/**
 * Field-keyed typed validation errors a save can return (slice C8). Each value is
 * a stable error code (`"blank"`, `"not_positive"`, …) the client localizes via
 * `forecasts.editor.errors.<code>`. `_summary` is the optional top-level summary
 * code for a failed save.
 */
export interface EditorFieldErrors {
	readonly [field: string]: string | undefined;
}

// ---------------------------------------------------------------------------
// Forecast V2 saved-assumption changed-region patch (slice C8).
//
// These interfaces type the payload `Forecasts::AssumptionsController#update`
// (PATCH /forecast/assumptions/:id) returns from
// `Forecasts::SavedAssumptionPatchReadModel#to_h`. It is the TYPED changed-region
// payload a save returns INSTEAD of a full workspace reload (spec "Patch budget",
// "Save endpoints"): only the regions a save may patch, plus version tokens. The
// client patches each region by its C3 `data-testid` region key, never replacing
// the workspace component tree.
// ---------------------------------------------------------------------------

/**
 * The version tokens a committed save returns. The client folds these into the
 * workspace store so dependent regions recompute their cache keys (spec "Live
 * Recompute Model").
 */
export interface SaveVersionTokens {
	readonly plan_version: number;
	readonly lock_version: number;
	readonly scenario_stack_key: string;
}

/**
 * `Forecasts::SavedAssumptionPatchReadModel#to_h` — the changed regions of a
 * committed assumption save. `selected_period` is `null` until projection output
 * is ready (deferred over-budget recompute), in which case `freshness.state` is
 * `recomputing` and the client keeps the prior inspector.
 */
export interface SavedAssumptionPatch {
	readonly saved_card: AssumptionCard;
	readonly selected_period: SelectedPeriodReadModel | null;
	readonly metric_strip: readonly SelectedPeriodMetric[];
	readonly issues: readonly IssueReadModel[];
	readonly freshness: ProjectionFreshness;
	readonly chart_data_token: string | null;
	readonly version_tokens: SaveVersionTokens;
}

/**
 * The typed conflict body a stale save returns (spec "Conflict Handling"). HTTP
 * 409. `conflict` is the stable conflict code; `context` preserves the editor /
 * period / scenario context so the client can re-anchor without losing the
 * user's place.
 */
export interface SaveConflict {
	readonly conflict: "stale_plan_version" | "stale_lock_version";
	readonly context: {
		readonly assumption_id?: string;
		readonly plan_version?: number;
		readonly lock_version?: number;
		readonly scenario_layer_id?: string | null;
	};
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
