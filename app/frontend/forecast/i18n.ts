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
  "forecasts.chart.metric_selector_label": "Chart metric",
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
  "forecasts.issue_panel.action_remove_assumption": "Remove assumption",
  "forecasts.issue_panel.action_choose_valid_milestone":
    "Choose a valid milestone",
  "forecasts.issue_panel.action_choose_date": "Use a fixed date",
  "forecasts.issue_panel.action_view": "View details",

  // Stable issue-code titles (spec "Issue Code Catalog"). The IssuePanel renders
  // these localized titles from an issue's message_key so the visible copy is
  // never the raw engine code. Mirror config/locales/views/forecasts/en.yml.
  "forecasts.issues.missing_fx_rate": "Missing exchange rate",
  "forecasts.issues.missing_security_price": "Missing security price",
  "forecasts.issues.stale_source_data": "Source data is out of date",
  "forecasts.issues.insufficient_history": "Not enough history yet",
  "forecasts.issues.missing_debt_terms": "Missing debt terms",
  "forecasts.issues.invalid_assumption_params": "Assumption needs attention",
  "forecasts.issues.invalid_milestone_reference": "Invalid milestone reference",
  "forecasts.issues.unknown_assumption_kind": "Unknown assumption type",
  "forecasts.issues.account_rule_conflict": "Conflicting account rules",
  "forecasts.issues.scenario_layer_conflict": "Conflicting scenario layers",

  // Typed assumption editor drawer (AssumptionEditor / useAssumptionEditor,
  // slice C7). The only interactive editor in the MVP is the salary form.
  "forecasts.editor.title": "Edit assumption",
  "forecasts.editor.close": "Close editor",
  "forecasts.editor.cancel": "Cancel",
  "forecasts.editor.save": "Save",
  "forecasts.editor.saving": "Saving…",
  "forecasts.editor.dirty_warning": "You have unsaved changes. Discard them?",
  "forecasts.editor.discard": "Discard changes",
  "forecasts.editor.keep_editing": "Keep editing",
  "forecasts.editor.loading": "Loading editor…",
  "forecasts.editor.load_error": "Couldn't open this editor. Try again.",
  "forecasts.editor.summary_error":
    "Some fields need attention before this can be saved.",
  // Save / conflict states (useAssumptionEditor save flow, slice C8).
  "forecasts.editor.saved": "Saved",
  "forecasts.editor.save_error": "Couldn't save. Try again.",
  "forecasts.editor.conflict_plan_version":
    "This plan changed elsewhere. Review the latest version, then save again.",
  "forecasts.editor.conflict_lock_version":
    "This assumption changed since you opened it. Reload and try again.",
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
  // Stable field error codes -> messages. Mirrors forecasts.editor.errors in
  // config/locales/views/forecasts/en.yml. Every code the assumption form objects
  // (Forecasts::Assumptions::BaseForm and subclasses) emit must have an entry here
  // so a save error never surfaces the raw key string: blank, not_a_number,
  // not_positive, unknown_currency, inclusion, invalid_date, end_before_start,
  // invalid_reference, not_permitted, stale_version.
  "forecasts.editor.errors.blank": "This field is required.",
  "forecasts.editor.errors.not_a_number": "Enter a valid number.",
  "forecasts.editor.errors.not_positive": "Enter a value greater than zero.",
  "forecasts.editor.errors.not_a_fraction": "Enter a value between 0 and 1.",
  "forecasts.editor.errors.unknown_currency": "Choose a supported currency.",
  "forecasts.editor.errors.inclusion": "Choose a valid option.",
  "forecasts.editor.errors.invalid_date": "Enter a valid date.",
  "forecasts.editor.errors.end_before_start":
    "The end date can't be before the start date.",
  "forecasts.editor.errors.invalid_reference":
    "That reference could not be found.",
  "forecasts.editor.errors.not_permitted":
    "You don't have access to that account or category.",
  "forecasts.editor.errors.stale_version":
    "This assumption changed since you opened it. Reload and try again.",

  // ProjectionLab-style stacked bar chart (Phase 1 redesign). The chart stacks
  // the existing per-period balance series (cash + investments above zero, debt
  // below zero) into gradient bars; copy here labels the plot selector, segments,
  // and scrub tooltip.
  "forecasts.chart.title": "Net worth projection",
  "forecasts.chart.plot_label": "Plot",
  "forecasts.chart.zoom_in": "Zoom in",
  "forecasts.chart.zoom_out": "Zoom out",
  "forecasts.chart.reset_zoom": "Reset zoom",
  "forecasts.chart.axis_year": "Year",
  "forecasts.chart.legend_label": "Account types",
  "forecasts.chart.tooltip_total": "Net worth",
  "forecasts.chart.segment.liquid_cash": "Cash",
  "forecasts.chart.segment.portfolio_value": "Investments",
  "forecasts.chart.segment.debt_balance": "Debt",
  "forecasts.chart.plot.net_worth": "Net Worth",
  "forecasts.chart.plot.liquid_cash": "Cash",
  "forecasts.chart.plot.portfolio_value": "Investments",
  "forecasts.chart.plot.debt_balance": "Debt",
  "forecasts.chart.plot.income": "Income",
  "forecasts.chart.plot.spending": "Spending",

  // Dark "Plans" sidebar (ProjectionLab-style left rail).
  "forecasts.sidebar.plans": "Plans",
  "forecasts.sidebar.current_projections": "Current Projections",
  "forecasts.sidebar.new_scenario": "New scenario",
  "forecasts.sidebar.scenarios": "Scenarios",
  "forecasts.sidebar.baseline": "Baseline",
  "forecasts.sidebar.version": "Version %{version}",
  "forecasts.sidebar.help": "Help center",
  "forecasts.sidebar.support": "Support",
  "forecasts.sidebar.collapse": "Collapse sidebar",
  "forecasts.sidebar.expand": "Expand sidebar",

  // Right-hand breakdown panel (ProjectionLab-style dense detail).
  "forecasts.breakdown.title": "Breakdown",
  "forecasts.breakdown.subtitle": "for %{period}",
  "forecasts.breakdown.net_worth": "Net worth",
  "forecasts.breakdown.assets": "Assets",
  "forecasts.breakdown.liabilities": "Liabilities",
  "forecasts.breakdown.cash": "Cash",
  "forecasts.breakdown.investments": "Investments",
  "forecasts.breakdown.debt": "Debt",
  "forecasts.breakdown.income": "Income",
  "forecasts.breakdown.spending": "Spending",
  "forecasts.breakdown.flows_title": "What moved this period",
  "forecasts.breakdown.no_flows": "No flows explain this period yet.",
  "forecasts.breakdown.expand_row": "Show detail",
  "forecasts.breakdown.collapse_row": "Hide detail",
  "forecasts.breakdown.no_period":
    "Select a year on the chart to see the breakdown.",
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
