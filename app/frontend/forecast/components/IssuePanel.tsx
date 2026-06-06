// Forecast V2 IssuePanel (slice C6).
//
// Renders the recoverable plan/source issues for the open plan (spec "Forecast
// Component Contracts" -> `IssuePanel`: "recoverable plan/source issues with
// impact and remediation actions"; spec "Error And Issue UX"). Each issue
// follows the spec copy structure: a title (what is wrong), context (affected
// output + period by display name), an impact line (what output is unavailable /
// held / excluded), and one or more concrete remediation actions.
//
// Privacy contract (spec "Error And Issue UX": "Raw UUIDs and engine-internal
// identifiers should not appear in user-facing failures"): this component reads
// ONLY the privacy-safe fields `IssueReadModel#to_h` exposes (code, severity,
// source, period, title, affected_output, impact, message_key, actions). It
// never receives or renders `debug_context` or raw entity UUIDs — those stay on
// the engine value object. The component also never fetches per-issue detail.
//
// Tokens only — no raw palette; severity tone maps to Sure status tokens. Copy
// resolves through the client i18n table (`ft`): the read model hands i18n keys
// (`message_key`, action codes) and display-name strings, never formatted UI
// copy.

import type { JSX } from "react";
import { ft } from "../i18n";
import type { IssueReadModel } from "../types/readModels";

// Severity -> tone classes + localized severity label. Blocking/error draw the
// strongest attention; warning is amber; info is muted.
const SEVERITY_STYLE: Readonly<
  Record<string, { border: string; text: string; labelKey: string }>
> = {
  blocking: {
    border: "border-destructive",
    text: "text-destructive",
    labelKey: "forecasts.issue_panel.severity_blocking",
  },
  error: {
    border: "border-destructive",
    text: "text-destructive",
    labelKey: "forecasts.issue_panel.severity_error",
  },
  warning: {
    border: "border-warning",
    text: "text-warning",
    labelKey: "forecasts.issue_panel.severity_warning",
  },
  info: {
    border: "border-primary",
    text: "text-subdued",
    labelKey: "forecasts.issue_panel.severity_info",
  },
};

function severityStyle(severity: string): (typeof SEVERITY_STYLE)[string] {
  return SEVERITY_STYLE[severity] ?? SEVERITY_STYLE.info;
}

// Remediation action code -> localized button label. Codes come from the spec
// "Issue Code Catalog" user-action column; unknown codes fall back to a generic
// "View details" so a new action never renders a raw code.
const ACTION_LABEL_KEY: Readonly<Record<string, string>> = {
  fetch_rates: "forecasts.issue_panel.action_fetch_rates",
  enter_fallback_rate: "forecasts.issue_panel.action_enter_fallback_rate",
  exclude_account: "forecasts.issue_panel.action_exclude_account",
  change_reporting_currency:
    "forecasts.issue_panel.action_change_reporting_currency",
  fetch_prices: "forecasts.issue_panel.action_fetch_prices",
  enter_fallback_price: "forecasts.issue_panel.action_enter_fallback_price",
  exclude_holding: "forecasts.issue_panel.action_exclude_holding",
  refresh_source_data: "forecasts.issue_panel.action_refresh_source_data",
  add_assumption: "forecasts.issue_panel.action_add_assumption",
  add_debt_terms: "forecasts.issue_panel.action_add_debt_terms",
  fix_fields: "forecasts.issue_panel.action_fix_fields",
  edit_assumption: "forecasts.issue_panel.action_edit_assumption",
  edit_account_rules: "forecasts.issue_panel.action_edit_account_rules",
  reorder_layers: "forecasts.issue_panel.action_reorder_layers",
  remove_assumption: "forecasts.issue_panel.action_remove_assumption",
  choose_valid_milestone: "forecasts.issue_panel.action_choose_valid_milestone",
  choose_date: "forecasts.issue_panel.action_choose_date",
};

function actionLabel(action: string): string {
  return ft(ACTION_LABEL_KEY[action] ?? "forecasts.issue_panel.action_view");
}

// The issue title: the read model's display-name title, falling back to the
// localized message-key copy when no display title is present. Never the raw
// code (which is for tests/`data-testid` only).
function issueTitle(issue: IssueReadModel): string {
  if (issue.title !== null && issue.title !== "") {
    return issue.title;
  }
  if (issue.message_key !== null && issue.message_key !== "") {
    return ft(issue.message_key);
  }
  return issue.code;
}

function IssueRow({ issue }: { readonly issue: IssueReadModel }): JSX.Element {
  const style = severityStyle(issue.severity);
  const hasContext =
    (issue.affected_output !== null && issue.affected_output !== "") ||
    (issue.period !== null && issue.period !== "");

  return (
    <li
      data-testid={`forecast-issue-${issue.code}`}
      data-issue-severity={issue.severity}
      className={`flex flex-col gap-2 rounded-lg border ${style.border} bg-container p-4`}
    >
      <div className="flex items-start justify-between gap-2">
        <h4 className="text-sm font-semibold text-primary">
          {issueTitle(issue)}
        </h4>
        <span
          className={`shrink-0 rounded-full border ${style.border} px-2 py-0.5 text-xs font-medium ${style.text}`}
        >
          {ft(style.labelKey)}
        </span>
      </div>

      {hasContext ? (
        <dl className="flex flex-col gap-0.5 text-xs text-subdued">
          {issue.affected_output !== null && issue.affected_output !== "" ? (
            <div className="flex gap-1">
              <dt className="font-medium">
                {ft("forecasts.issue_panel.affects_label")}:
              </dt>
              <dd className="min-w-0 truncate">{issue.affected_output}</dd>
            </div>
          ) : null}
          {issue.period !== null && issue.period !== "" ? (
            <div className="flex gap-1">
              <dt className="font-medium">
                {ft("forecasts.issue_panel.period_label")}:
              </dt>
              <dd className="tabular-nums">{issue.period}</dd>
            </div>
          ) : null}
        </dl>
      ) : null}

      {issue.impact !== null && issue.impact !== "" ? (
        <p className="text-sm text-secondary">
          <span className="font-medium text-subdued">
            {ft("forecasts.issue_panel.impact_label")}:{" "}
          </span>
          {issue.impact}
        </p>
      ) : null}

      {issue.actions.length > 0 ? (
        <div className="flex flex-wrap gap-2 pt-1">
          {issue.actions.map((action) => (
            <button
              key={action}
              type="button"
              data-testid={`forecast-issue-action-${issue.code}-${action}`}
              className="rounded-lg border border-primary px-3 py-1 text-xs font-medium text-primary hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400"
            >
              {actionLabel(action)}
            </button>
          ))}
        </div>
      ) : null}
    </li>
  );
}

export interface IssuePanelProps {
  readonly issues: readonly IssueReadModel[];
  /** Stable region id for scoped patches / tests. */
  readonly regionKey?: string;
  /** Stable region cache key (plan version + scenario stack) for patch targets. */
  readonly cacheKey?: string;
}

export default function IssuePanel({
  issues,
  regionKey = "forecast-issue-panel",
  cacheKey,
}: IssuePanelProps): JSX.Element {
  const count = issues.length;
  const limitedKey =
    count === 1
      ? "forecasts.issue_panel.limited_one"
      : "forecasts.issue_panel.limited_other";

  return (
    <section
      data-testid={regionKey}
      data-region={regionKey}
      data-cache-key={cacheKey}
      data-issue-count={count}
      aria-label={ft("forecasts.issue_panel.title")}
      className="flex flex-col gap-3 rounded-xl border border-primary bg-surface p-4"
    >
      <header className="flex items-baseline justify-between gap-2">
        <h3 className="text-sm font-semibold text-primary">
          {ft("forecasts.issue_panel.title")}
        </h3>
        {count > 0 ? (
          <span className="text-xs text-subdued">
            {ft(limitedKey, { count })}
          </span>
        ) : null}
      </header>

      {count === 0 ? (
        <p className="text-sm text-subdued">
          {ft("forecasts.issue_panel.none")}
        </p>
      ) : (
        <ul className="flex flex-col gap-3">
          {issues.map((issue) => (
            <IssueRow key={issue.code} issue={issue} />
          ))}
        </ul>
      )}
    </section>
  );
}
