// Forecast V2 SelectedPeriodInspector (slice C5).
//
// Renders the one settled period's detail (spec "Forecast Component Contracts" ->
// `SelectedPeriodInspector`: "explanation lines, active assumption links, issues,
// and actual/projected labels for one period"):
//
//   - the metric strip detail (reusing the shared MetricStrip),
//   - trace-backed explanation lines, each with an actual/projected provenance
//     label (spec "Explain A Cash Dip": "identifies whether values are actual,
//     projected, inherited, or scenario-layer effects"),
//   - active assumption links (the assumption ids the period activates), and
//   - the period's privacy-safe issues.
//
// Data lifecycle is owned by `usePeriodPayloadCache` (this component never
// fetches, never persists, never recomputes); it renders whatever that hook
// serves and shows loading/error/empty states around it. Tokens only — no raw
// palette. Money/value cells carry `privacy-sensitive` so the app-wide
// privacy-mode toggle blurs them with no forecast-specific JS. Copy comes from
// the client i18n table (`ft`) or the read model's i18n keys; the read model
// never formats UI strings.

import type { JSX } from "react";
import type {
  PeriodPayloadStatus,
  UsePeriodPayloadCacheResult,
} from "../hooks/usePeriodPayloadCache";
import { ft } from "../i18n";
import type {
  SelectedPeriodExplanationLine,
  SelectedPeriodIssueLine,
  SelectedPeriodReadModel,
} from "../types/readModels";
import MetricStrip, { metricsToStripEntries } from "./MetricStrip";

// An explanation line's `source` carries its provenance. `trace` lines are
// projected from assumptions; reconciled/actual flows would arrive as `actual`.
// Maps the read model's source onto the localized actual/projected label.
const PROVENANCE_LABEL_KEY: Readonly<Record<string, string>> = {
  actual: "forecasts.inspector.label_actual",
  trace: "forecasts.inspector.label_projected",
  projected: "forecasts.inspector.label_projected",
  inherited: "forecasts.inspector.label_inherited",
  scenario: "forecasts.inspector.label_scenario",
};

function provenanceLabel(source: string): string {
  return ft(
    PROVENANCE_LABEL_KEY[source] ?? "forecasts.inspector.label_projected",
  );
}

// Format a canonical decimal-string amount for display without losing the
// canonical string as the source of truth.
function formatAmount(amount: string | null): string {
  if (amount === null || amount === "") {
    return "—";
  }
  const parsed = Number.parseFloat(amount);
  if (Number.isNaN(parsed)) {
    return amount;
  }
  return new Intl.NumberFormat(undefined, {
    maximumFractionDigits: 2,
  }).format(parsed);
}

function directionLabel(direction: string | null): string | null {
  if (direction === "inflow") {
    return ft("forecasts.inspector.direction_inflow");
  }
  if (direction === "outflow") {
    return ft("forecasts.inspector.direction_outflow");
  }
  return null;
}

function ExplanationLine({
  line,
  index,
}: {
  readonly line: SelectedPeriodExplanationLine;
  readonly index: number;
}): JSX.Element {
  const direction = directionLabel(line.direction);
  return (
    <li
      data-testid={`forecast-explanation-line-${index}`}
      className="flex items-center justify-between gap-3 rounded-lg border border-primary bg-surface px-3 py-2"
    >
      <span className="flex min-w-0 items-center gap-2">
        <span className="truncate text-sm text-primary">
          {line.explanation_key ? ft(line.explanation_key) : line.kind}
        </span>
        <span className="shrink-0 rounded-full border border-primary px-2 py-0.5 text-xs text-subdued">
          {provenanceLabel(line.source)}
        </span>
      </span>
      <span className="privacy-sensitive shrink-0 text-sm font-medium tabular-nums text-primary">
        {formatAmount(line.amount)}
        {direction ? (
          <span className="ml-1 text-xs text-subdued">{direction}</span>
        ) : null}
      </span>
    </li>
  );
}

function IssueLine({
  issue,
}: {
  readonly issue: SelectedPeriodIssueLine;
}): JSX.Element {
  return (
    <li
      data-testid={`forecast-period-issue-${issue.code}`}
      className="rounded-lg border border-warning bg-surface px-3 py-2 text-sm text-warning"
    >
      {ft(issue.message_key)}
    </li>
  );
}

function PeriodDetail({
  payload,
  regionKey,
  onOpenAssumption,
}: {
  readonly payload: SelectedPeriodReadModel;
  readonly regionKey: string;
  readonly onOpenAssumption?: (assumptionId: string) => void;
}): JSX.Element {
  const metricEntries = metricsToStripEntries(payload.metrics);
  return (
    <div className="flex flex-col gap-5">
      <header className="flex items-baseline justify-between gap-2">
        <h2 className="text-sm font-semibold text-primary">
          {ft("forecasts.inspector.title")}
        </h2>
        <span className="text-xs text-subdued tabular-nums">
          {payload.period_key}
        </span>
      </header>

      <section aria-label={ft("forecasts.inspector.metrics_title")}>
        <MetricStrip
          entries={metricEntries}
          regionKey={`${regionKey}-metrics`}
        />
      </section>

      <section className="flex flex-col gap-2">
        <h3 className="text-xs font-medium uppercase tracking-wide text-subdued">
          {ft("forecasts.inspector.explanation_title")}
        </h3>
        {payload.explanation.length === 0 ? (
          <p className="text-sm text-subdued">
            {ft("forecasts.inspector.explanation_empty")}
          </p>
        ) : (
          <ul className="flex flex-col gap-2">
            {payload.explanation.map((line, index) => (
              <ExplanationLine
                // Explanation lines have no stable id; index within the stable
                // display-ordered list is the key.
                key={`${line.kind}-${line.explanation_key ?? index}`}
                line={line}
                index={index}
              />
            ))}
          </ul>
        )}
      </section>

      <section className="flex flex-col gap-2">
        <h3 className="text-xs font-medium uppercase tracking-wide text-subdued">
          {ft("forecasts.inspector.assumptions_title")}
        </h3>
        {payload.active_assumption_ids.length === 0 ? (
          <p className="text-sm text-subdued">
            {ft("forecasts.inspector.assumptions_empty")}
          </p>
        ) : (
          <ul className="flex flex-wrap gap-2">
            {payload.active_assumption_ids.map((id) => (
              <li key={id}>
                <button
                  type="button"
                  id={`forecast-inspector-assumption-${id}`}
                  data-testid={`forecast-assumption-link-${id}`}
                  onClick={() => onOpenAssumption?.(id)}
                  disabled={onOpenAssumption === undefined}
                  className="inline-flex rounded-full border border-primary bg-surface px-3 py-1 text-xs font-medium text-primary hover:bg-container focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {ft("forecasts.inspector.assumption_link", {
                    id: id.slice(0, 8),
                  })}
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="flex flex-col gap-2">
        <h3 className="text-xs font-medium uppercase tracking-wide text-subdued">
          {ft("forecasts.inspector.issues_title")}
        </h3>
        {payload.issues.length === 0 ? (
          <p className="text-sm text-subdued">
            {ft("forecasts.inspector.no_issues")}
          </p>
        ) : (
          <ul className="flex flex-col gap-2">
            {payload.issues.map((issue) => (
              <IssueLine key={issue.code} issue={issue} />
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

export interface SelectedPeriodInspectorProps {
  /** The served selected-period payload (seed/cache/fetch); null when none. */
  readonly payload: SelectedPeriodReadModel | null;
  /** Where the current selection sits in the data-serving lifecycle. */
  readonly status: PeriodPayloadStatus;
  /** Forces a refresh of the current selection (explicit refresh path). */
  readonly refresh?: UsePeriodPayloadCacheResult["refresh"];
  /** Stable region id for scoped patches / tests. */
  readonly regionKey?: string;
  /** Stable region cache key (plan version + scenario stack) for patch targets. */
  readonly cacheKey?: string;
  /**
   * Opens the type-specific editor drawer for an active assumption IN PLACE
   * (spec "Editor Contracts": "must not navigate away from /forecast"). Wired to
   * the same `editor.open` handler the assumption cards use, so clicking an
   * assumption here never leaves the workspace or loses the selected period /
   * scenario stack. When omitted, the chips render disabled (no navigation).
   */
  readonly onOpenAssumption?: (assumptionId: string) => void;
}

export default function SelectedPeriodInspector({
  payload,
  status,
  refresh,
  regionKey = "forecast-selected-period",
  cacheKey,
  onOpenAssumption,
}: SelectedPeriodInspectorProps): JSX.Element {
  const isError = status === "error";
  const isLoadingFirst = status === "loading" && payload === null;
  const showEmpty =
    payload === null && (status === "idle" || status === "ready");

  return (
    <section
      data-testid={regionKey}
      data-region={regionKey}
      data-cache-key={cacheKey}
      data-status={status}
      aria-busy={status === "loading"}
      className="rounded-xl border border-primary bg-container p-6"
    >
      {isError ? (
        <div className="flex flex-col items-start gap-3">
          <p className="text-sm text-destructive">
            {ft("forecasts.inspector.error")}
          </p>
          {refresh ? (
            <button
              type="button"
              onClick={refresh}
              className="rounded-lg border border-primary px-3 py-1 text-sm font-medium text-primary hover:bg-surface"
            >
              {ft("forecasts.inspector.refresh")}
            </button>
          ) : null}
        </div>
      ) : isLoadingFirst ? (
        <p className="text-sm text-subdued">
          {ft("forecasts.inspector.loading")}
        </p>
      ) : showEmpty ? (
        <p className="text-sm text-subdued">
          {ft("forecasts.inspector.no_period")}
        </p>
      ) : payload ? (
        <PeriodDetail
          payload={payload}
          regionKey={regionKey}
          onOpenAssumption={onOpenAssumption}
        />
      ) : null}
    </section>
  );
}
