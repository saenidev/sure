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

	// Assumption rail (AssumptionGroup / AssumptionCard, slice C6).
	"forecasts.assumptions.title": "Assumptions",
	"forecasts.assumptions.empty":
		"No assumptions yet. Add income or spending to shape the projection.",
	"forecasts.assumptions.group_count.one": "%{count} assumption",
	"forecasts.assumptions.group_count.other": "%{count} assumptions",
	"forecasts.assumptions.active_count": "%{count} active in this period",
	"forecasts.assumptions.collapse": "Collapse %{group}",
	"forecasts.assumptions.expand": "Expand %{group}",
	"forecasts.assumptions.active_in_period": "Active this period",
	"forecasts.assumptions.edit": "Edit",
	"forecasts.assumptions.more_actions": "More actions",
	"forecasts.assumptions.action_edit": "Edit",
	"forecasts.assumptions.action_duplicate": "Duplicate",
	"forecasts.assumptions.action_move_to_scenario": "Move to scenario layer",
	"forecasts.assumptions.action_disable": "Disable",
	"forecasts.assumptions.action_archive": "Archive",
	"forecasts.assumptions.action_delete": "Delete",

	// Localized assumption-group headers (AssumptionGroup title_key).
	"forecasts.assumption_groups.salary": "Income",
	"forecasts.assumption_groups.living_expense": "Spending",

	// Status / provenance badges on an assumption card.
	"forecasts.badges.review_suggested": "Review suggested",
	"forecasts.badges.derived": "From your data",
	"forecasts.badges.low_confidence": "Low confidence",
	"forecasts.badges.disabled": "Disabled",
	"forecasts.badges.scenario": "Scenario",
	"forecasts.badges.issue": "Needs attention",

	// Financial-planning card copy contract (AssumptionCard).
	"forecasts.cards.amount_per.month": "%{amount}/mo",
	"forecasts.cards.amount_per.year": "%{amount}/yr",
	"forecasts.cards.amount_per.week": "%{amount}/wk",
	"forecasts.cards.amount_per.quarter": "%{amount}/qtr",
	"forecasts.cards.amount_per.one_time": "%{amount} once",
	"forecasts.cards.amount_unknown": "Amount not set",
	"forecasts.cards.time_from_until": "from %{start} until %{end}",
	"forecasts.cards.time_from": "from %{start}",
	"forecasts.cards.time_until": "until %{end}",
	"forecasts.cards.time_ongoing": "ongoing",
	"forecasts.cards.growth_annual": "%{rate} annual growth",
	"forecasts.cards.inflation_linked": "inflation-linked",
	"forecasts.cards.source_derived": "derived from your data",
	"forecasts.cards.no_secondary": "No additional detail",

	// Recoverable plan/source issue panel (IssuePanel, slice C6).
	"forecasts.issue_panel.title": "Issues",
	"forecasts.issue_panel.none": "No issues. Your projection is complete.",
	"forecasts.issue_panel.limited_one":
		"%{count} issue is limiting this projection.",
	"forecasts.issue_panel.limited_other":
		"%{count} issues are limiting this projection.",
	"forecasts.issue_panel.impact_label": "Impact",
	"forecasts.issue_panel.affects_label": "Affects",
	"forecasts.issue_panel.period_label": "Period",
	"forecasts.issue_panel.severity_blocking": "Blocking",
	"forecasts.issue_panel.severity_error": "Error",
	"forecasts.issue_panel.severity_warning": "Warning",
	"forecasts.issue_panel.severity_info": "Info",
	"forecasts.issue_panel.action_fetch_rates": "Fetch rates",
	"forecasts.issue_panel.action_enter_fallback_rate": "Enter fallback rate",
	"forecasts.issue_panel.action_exclude_account": "Exclude account",
	"forecasts.issue_panel.action_change_reporting_currency":
		"Change reporting currency",
	"forecasts.issue_panel.action_fetch_prices": "Fetch prices",
	"forecasts.issue_panel.action_enter_fallback_price": "Enter fallback price",
	"forecasts.issue_panel.action_exclude_holding": "Exclude holding",
	"forecasts.issue_panel.action_refresh_source_data": "Refresh source data",
	"forecasts.issue_panel.action_add_assumption": "Add assumption",
	"forecasts.issue_panel.action_add_debt_terms": "Add debt terms",
	"forecasts.issue_panel.action_fix_fields": "Fix fields",
	"forecasts.issue_panel.action_edit_assumption": "Edit assumption",
	"forecasts.issue_panel.action_edit_account_rules": "Edit account rules",
	"forecasts.issue_panel.action_reorder_layers": "Reorder layers",
	"forecasts.issue_panel.action_view": "View details",

	// Typed assumption editor drawer (AssumptionEditor / useAssumptionEditor,
	// slice C7). The only interactive editor in the MVP is the salary form.
	"forecasts.editor.title": "Edit assumption",
	"forecasts.editor.close": "Close editor",
	"forecasts.editor.cancel": "Cancel",
	"forecasts.editor.save": "Save",
	"forecasts.editor.saving": "Saving…",
	"forecasts.editor.dirty_warning":
		"You have unsaved changes. Discard them?",
	"forecasts.editor.discard": "Discard changes",
	"forecasts.editor.keep_editing": "Keep editing",
	"forecasts.editor.loading": "Loading editor…",
	"forecasts.editor.load_error": "Couldn't open this editor. Try again.",
	"forecasts.editor.summary_error":
		"Some fields need attention before this can be saved.",
	"forecasts.editor.scenario_baseline": "Editing the baseline plan",
	"forecasts.editor.scenario_layer": "Editing scenario layer %{layer}",
	// Collapsed editor section headers + summary lines.
	"forecasts.editor.time_range": "Timing",
	"forecasts.editor.time_range_summary": "%{start} → %{end}",
	"forecasts.editor.time_range_ongoing": "Ongoing",
	"forecasts.editor.change_over_time": "Change over time",
	"forecasts.editor.change_over_time_growth": "%{rate} annual growth",
	"forecasts.editor.change_over_time_inflation": "%{rate} inflation",
	"forecasts.editor.change_over_time_flat": "No change over time",
	"forecasts.editor.source": "Source",
	"forecasts.editor.source_summary": "%{origin} · %{review}",
	// Salary form fields.
	"forecasts.editor.salary.heading": "Salary",
	"forecasts.editor.salary.name_label": "Name",
	"forecasts.editor.salary.amount_label": "Amount",
	"forecasts.editor.salary.currency_label": "Currency",
	"forecasts.editor.salary.person_key_label": "Earner",
	"forecasts.editor.salary.gross_or_net_label": "Gross or net",
	"forecasts.editor.salary.gross_or_net_gross": "Gross",
	"forecasts.editor.salary.gross_or_net_net": "Net",
	"forecasts.editor.salary.frequency_label": "Frequency",
	"forecasts.editor.salary.frequency_annual": "Annual",
	"forecasts.editor.salary.frequency_monthly": "Monthly",
	"forecasts.editor.salary.frequency_biweekly": "Biweekly",
	"forecasts.editor.salary.frequency_weekly": "Weekly",
	"forecasts.editor.salary.growth_policy_label": "Growth",
	"forecasts.editor.salary.growth_policy_flat": "No growth",
	"forecasts.editor.salary.growth_policy_fixed_rate": "Fixed annual rate",
	"forecasts.editor.salary.growth_rate_label": "Growth rate",
	"forecasts.editor.salary.starts_on_label": "Starts on",
	"forecasts.editor.salary.ends_on_label": "Ends on",
	// Stable field error codes -> messages (mirror the SalaryForm error codes).
	"forecasts.editor.errors.blank": "This field is required.",
	"forecasts.editor.errors.not_a_number": "Enter a valid number.",
	"forecasts.editor.errors.not_positive": "Enter a value greater than zero.",
	"forecasts.editor.errors.inclusion": "Choose a valid option.",
	"forecasts.editor.errors.invalid_date": "Enter a valid date.",
	"forecasts.editor.errors.end_before_start":
		"The end date can't be before the start date.",
	"forecasts.editor.errors.not_found": "That reference could not be found.",
	"forecasts.editor.errors.stale":
		"This assumption changed since you opened it. Reload and try again.",
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
