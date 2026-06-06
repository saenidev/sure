// Forecast V2 client copy table (slice C3).
//
// The Forecast V2 workspace is a route-scoped Inertia/React island; it has no
// access to Rails' `t()` at render time. The server passes localized strings via
// props where it owns them (e.g. `plan.name`) and passes i18n KEYS where the
// client must localize (the read models' `label_key` / `message_key` / lifecycle
// state, per the read-model contract that read models never format UI strings).
//
// This module is the single client-side resolver for those keys. Every key here
// mirrors a key in config/locales/views/forecasts/en.yml (the canonical source
// of truth), so adding a locale later means generating this table from the same
// keys rather than scattering English literals through components. Keep this the
// ONLY place Forecast V2 component copy lives.

// Flat key -> English string. Mirrors config/locales/views/forecasts/en.yml.
const COPY: Readonly<Record<string, string>> = {
	// Workspace shell chrome.
	"forecasts.workspace.title": "Forecast",
	"forecasts.workspace.plan_version": "Plan v%{version}",
	"forecasts.workspace.scenario_stack": "Scenario stack",
	"forecasts.workspace.baseline": "Baseline",
	"forecasts.workspace.metric_strip_label": "Key metrics",
	"forecasts.workspace.no_metrics": "No metrics for this period yet.",
	"forecasts.workspace.as_of": "as of %{date}",
	"forecasts.workspace.not_computed": "not computed yet",
	"forecasts.workspace.no_period_selected": "Select a period",

	// Selected-period inspector (SelectedPeriodInspector / usePeriodPayloadCache,
	// slice C5).
	"forecasts.inspector.title": "Period detail",
	"forecasts.inspector.metrics_title": "Metrics",
	"forecasts.inspector.explanation_title": "What explains this period",
	"forecasts.inspector.explanation_empty": "No flows explain this period yet.",
	"forecasts.inspector.assumptions_title": "Active assumptions",
	"forecasts.inspector.assumptions_empty":
		"No assumptions are active in this period.",
	"forecasts.inspector.assumption_link": "Assumption %{id}",
	"forecasts.inspector.issues_title": "Issues",
	"forecasts.inspector.no_issues": "No issues for this period.",
	"forecasts.inspector.no_period":
		"Select a period on the chart to see what explains it.",
	"forecasts.inspector.loading": "Loading period detail…",
	"forecasts.inspector.error":
		"Couldn't load this period. Try selecting it again.",
	"forecasts.inspector.refresh": "Refresh",
	"forecasts.inspector.label_actual": "Actual",
	"forecasts.inspector.label_projected": "Projected",
	"forecasts.inspector.label_inherited": "Inherited",
	"forecasts.inspector.label_scenario": "Scenario",
	"forecasts.inspector.direction_inflow": "in",
	"forecasts.inspector.direction_outflow": "out",

	// Projection chart (ProjectionChart / useProjectionChart, slice C4).
	"forecasts.chart.label": "Projection chart",
	"forecasts.chart.empty": "No projection series to chart yet.",
	"forecasts.chart.scrubber_label": "Projection scrubber",
	"forecasts.chart.selected_period":
		"Selected period %{period}, value %{value}.",
	"forecasts.chart.summary_caption": "Projected %{metric} for each period.",
	"forecasts.chart.summary_period": "Period",
	"forecasts.chart.summary_value": "Value",

	// Freshness lifecycle states (drive the FreshnessIndicator).
	"forecasts.freshness.fresh": "Up to date",
	"forecasts.freshness.stale": "Out of date",
	"forecasts.freshness.recomputing": "Recomputing",
	"forecasts.freshness.failed": "Projection failed",
	"forecasts.freshness.superseded": "Superseded",
	"forecasts.freshness.uncomputed": "Not computed",
	"forecasts.freshness.source_limited": "Limited by source data",

	// Selected-period metric strip labels (SelectedPeriodReadModel label_keys).
	"forecasts.metrics.net_worth": "Net worth",
	"forecasts.metrics.liquid_cash": "Liquid cash",
	"forecasts.metrics.income": "Income",
	"forecasts.metrics.spending": "Spending",
	"forecasts.metrics.debt_balance": "Debt",
	"forecasts.metrics.portfolio_value": "Portfolio",
	"forecasts.metrics.runway_days": "Cash runway",
};

/**
 * Resolves a Forecast V2 i18n key to its English string, interpolating any
 * `%{name}` placeholders. Falls back to the raw key so a missing key is visible
 * (and greppable) rather than silently blank.
 */
export function ft(
	key: string,
	interpolations: Readonly<Record<string, string | number>> = {},
): string {
	const template = COPY[key];
	if (template === undefined) {
		return key;
	}
	return template.replace(/%\{(\w+)\}/g, (match, name: string) => {
		const value = interpolations[name];
		return value === undefined ? match : String(value);
	});
}
