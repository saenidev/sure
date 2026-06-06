// Forecast V2 BreakdownPanel — ProjectionLab-style dense breakdown
// (Phase 1 redesign).
//
// The right-hand panel from ProjectionLab's "Current Projections" dashboard: a
// dense, scannable breakdown of the selected period — Net worth headline, an
// Assets group (Cash + Investments) and Liabilities group (Debt) as expandable
// rows, a Cashflow group (Income + Spending), the trace-backed flows that moved
// the period, the active assumptions, and any period issues.
//
// It carries the `forecast-selected-period` region id (the same scoped-patch
// target + test contract the inspector held), so a committed save still patches
// exactly this region and the proof-slice selectors keep resolving. Data
// lifecycle is owned by `usePeriodPayloadCache`; this renders what it serves and
// shows loading/error/empty states. It never fetches, persists, or recomputes.
// Money cells carry `privacy-sensitive` so the app-wide privacy toggle blurs
// them. Colors are forecast-scoped raw hex (faithful ProjectionLab palette).

import { type JSX, type ReactNode, useMemo } from "react";
import type {
  PeriodPayloadStatus,
  UsePeriodPayloadCacheResult,
} from "../hooks/usePeriodPayloadCache";
import { ft } from "../i18n";
import type {
  SelectedPeriodExplanationLine,
  SelectedPeriodReadModel,
} from "../types/readModels";

const SEGMENT_DOT: Readonly<Record<string, string>> = {
  liquid_cash: "#6366F1",
  portfolio_value: "#14B8A6",
  debt_balance: "#FB923C",
};

const PROVENANCE_LABEL_KEY: Readonly<Record<string, string>> = {
  actual: "forecasts.inspector.label_actual",
  trace: "forecasts.inspector.label_projected",
  projected: "forecasts.inspector.label_projected",
  inherited: "forecasts.inspector.label_inherited",
  scenario: "forecasts.inspector.label_scenario",
};

function useMoney(currency?: string) {
  return useMemo(() => {
    const build = (opts: Intl.NumberFormatOptions): Intl.NumberFormat => {
      try {
        return new Intl.NumberFormat(
          undefined,
          currency ? { style: "currency", currency, ...opts } : opts,
        );
      } catch {
        return new Intl.NumberFormat(undefined, opts);
      }
    };
    const fmt = build({ maximumFractionDigits: 0 });
    return (value: string | null): string => {
      if (value === null || value === "") {
        return "—";
      }
      const parsed = Number.parseFloat(value);
      return Number.isNaN(parsed) ? value : fmt.format(parsed);
    };
  }, [currency]);
}

function Row({
  label,
  value,
  dot,
  emphasis,
}: {
  readonly label: string;
  readonly value: string;
  readonly dot?: string;
  readonly emphasis?: boolean;
}): JSX.Element {
  return (
    <div className="flex items-center justify-between gap-3 py-1.5">
      <span className="flex items-center gap-2 text-sm text-[#475569]">
        {dot ? (
          <span
            aria-hidden="true"
            className="inline-block size-2 rounded-full"
            style={{ backgroundColor: dot }}
          />
        ) : null}
        {label}
      </span>
      <span
        className={`privacy-sensitive tabular-nums ${
          emphasis
            ? "text-sm font-semibold text-[#0F172A]"
            : "text-sm text-[#334155]"
        }`}
      >
        {value}
      </span>
    </div>
  );
}

// An expandable group row (PL-style chevron disclosure). Native <details> keeps
// it accessible and stateful without extra JS.
function Group({
  label,
  total,
  children,
  open,
}: {
  readonly label: string;
  readonly total: string;
  readonly children: ReactNode;
  readonly open?: boolean;
}): JSX.Element {
  return (
    <details
      open={open}
      className="group border-b border-[#EEF2F6] py-2 last:border-b-0"
    >
      <summary className="flex cursor-pointer list-none items-center justify-between gap-3 py-0.5 [&::-webkit-details-marker]:hidden">
        <span className="flex items-center gap-1.5 text-sm font-medium text-[#0F172A]">
          <svg
            aria-hidden="true"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            className="size-3.5 text-[#94A3B8] transition-transform group-open:rotate-90"
          >
            <path d="m9 18 6-6-6-6" />
          </svg>
          {label}
        </span>
        <span className="privacy-sensitive text-sm font-semibold tabular-nums text-[#0F172A]">
          {total}
        </span>
      </summary>
      <div className="pl-5">{children}</div>
    </details>
  );
}

function FlowLine({
  line,
  money,
}: {
  readonly line: SelectedPeriodExplanationLine;
  readonly money: (value: string | null) => string;
}): JSX.Element {
  const provenance = ft(
    PROVENANCE_LABEL_KEY[line.source] ?? "forecasts.inspector.label_projected",
  );
  const isInflow = line.direction === "inflow";
  return (
    <div className="flex items-center justify-between gap-3 py-1.5">
      <span className="flex min-w-0 items-center gap-2">
        <span className="truncate text-sm text-[#475569]">
          {line.explanation_key ? ft(line.explanation_key) : line.kind}
        </span>
        <span className="shrink-0 rounded-full bg-[#F1F5F9] px-1.5 py-0.5 text-[10px] font-medium text-[#64748B]">
          {provenance}
        </span>
      </span>
      <span
        className={`privacy-sensitive shrink-0 text-sm font-medium tabular-nums ${
          isInflow ? "text-[#0D9488]" : "text-[#334155]"
        }`}
      >
        {isInflow ? "+" : ""}
        {money(line.amount)}
      </span>
    </div>
  );
}

function PanelShell({
  regionKey,
  cacheKey,
  status,
  children,
}: {
  readonly regionKey: string;
  readonly cacheKey?: string;
  readonly status: PeriodPayloadStatus;
  readonly children: ReactNode;
}): JSX.Element {
  return (
    <section
      data-testid={regionKey}
      data-region={regionKey}
      data-cache-key={cacheKey}
      data-status={status}
      aria-busy={status === "loading"}
      aria-label={ft("forecasts.breakdown.title")}
      className="flex w-full flex-col rounded-2xl border border-[#E3E8EF] bg-white p-5 shadow-[0_1px_3px_rgba(15,23,42,0.04)] lg:w-80 lg:shrink-0"
    >
      {children}
    </section>
  );
}

export interface BreakdownPanelProps {
  readonly payload: SelectedPeriodReadModel | null;
  readonly status: PeriodPayloadStatus;
  readonly refresh?: UsePeriodPayloadCacheResult["refresh"];
  readonly currency?: string;
  readonly regionKey?: string;
  readonly cacheKey?: string;
  readonly onOpenAssumption?: (assumptionId: string) => void;
}

export default function BreakdownPanel({
  payload,
  status,
  refresh,
  currency,
  regionKey = "forecast-selected-period",
  cacheKey,
  onOpenAssumption,
}: BreakdownPanelProps): JSX.Element {
  const money = useMoney(currency);
  const metrics = useMemo(() => {
    const map = new Map<string, string | null>();
    for (const metric of payload?.metrics ?? []) {
      map.set(metric.key, metric.value);
    }
    return map;
  }, [payload]);

  const isError = status === "error";
  const isLoadingFirst = status === "loading" && payload === null;

  if (isError) {
    return (
      <PanelShell regionKey={regionKey} cacheKey={cacheKey} status={status}>
        <p className="text-sm text-[#DC2626]">
          {ft("forecasts.inspector.error")}
        </p>
        {refresh ? (
          <button
            type="button"
            onClick={refresh}
            className="mt-3 self-start rounded-lg border border-[#E3E8EF] px-3 py-1 text-sm font-medium text-[#0F172A] hover:bg-[#F8FAFC]"
          >
            {ft("forecasts.inspector.refresh")}
          </button>
        ) : null}
      </PanelShell>
    );
  }

  if (isLoadingFirst) {
    return (
      <PanelShell regionKey={regionKey} cacheKey={cacheKey} status={status}>
        <p className="text-sm text-[#64748B]">
          {ft("forecasts.inspector.loading")}
        </p>
      </PanelShell>
    );
  }

  if (payload === null) {
    return (
      <PanelShell regionKey={regionKey} cacheKey={cacheKey} status={status}>
        <p className="text-sm text-[#64748B]">
          {ft("forecasts.breakdown.no_period")}
        </p>
      </PanelShell>
    );
  }

  const assetsTotal =
    (Number.parseFloat(metrics.get("liquid_cash") ?? "0") || 0) +
    (Number.parseFloat(metrics.get("portfolio_value") ?? "0") || 0);

  return (
    <PanelShell regionKey={regionKey} cacheKey={cacheKey} status={status}>
      {/* Headline: net worth for the selected period. */}
      <header className="border-b border-[#EEF2F6] pb-4">
        <p className="text-xs font-medium uppercase tracking-wider text-[#94A3B8]">
          {ft("forecasts.breakdown.net_worth")}
        </p>
        <p className="privacy-sensitive mt-1 text-3xl font-bold tabular-nums text-[#0F172A]">
          {money(metrics.get("net_worth") ?? null)}
        </p>
        <p className="mt-1 text-xs text-[#94A3B8]">
          {ft("forecasts.breakdown.subtitle", { period: payload.period_key })}
        </p>
      </header>

      {/* Assets / Liabilities. */}
      <div className="flex flex-col pt-2">
        <Group
          label={ft("forecasts.breakdown.assets")}
          total={money(String(assetsTotal))}
          open
        >
          <Row
            label={ft("forecasts.breakdown.cash")}
            value={money(metrics.get("liquid_cash") ?? null)}
            dot={SEGMENT_DOT.liquid_cash}
          />
          <Row
            label={ft("forecasts.breakdown.investments")}
            value={money(metrics.get("portfolio_value") ?? null)}
            dot={SEGMENT_DOT.portfolio_value}
          />
        </Group>
        <Group
          label={ft("forecasts.breakdown.liabilities")}
          total={money(metrics.get("debt_balance") ?? null)}
        >
          <Row
            label={ft("forecasts.breakdown.debt")}
            value={money(metrics.get("debt_balance") ?? null)}
            dot={SEGMENT_DOT.debt_balance}
          />
        </Group>
      </div>

      {/* Cashflow. */}
      <div className="mt-3 border-t border-[#EEF2F6] pt-3">
        <Row
          label={ft("forecasts.breakdown.income")}
          value={money(metrics.get("income") ?? null)}
          emphasis
        />
        <Row
          label={ft("forecasts.breakdown.spending")}
          value={money(metrics.get("spending") ?? null)}
          emphasis
        />
      </div>

      {/* Flows that moved this period. */}
      <div className="mt-3 border-t border-[#EEF2F6] pt-3">
        <p className="pb-1 text-xs font-medium uppercase tracking-wider text-[#94A3B8]">
          {ft("forecasts.breakdown.flows_title")}
        </p>
        {payload.explanation.length === 0 ? (
          <p className="py-1.5 text-sm text-[#94A3B8]">
            {ft("forecasts.breakdown.no_flows")}
          </p>
        ) : (
          payload.explanation.map((line, index) => (
            <FlowLine
              key={`${line.kind}-${line.explanation_key ?? index}`}
              line={line}
              money={money}
            />
          ))
        )}
      </div>

      {/* Active assumptions (open the typed editor in place). */}
      {payload.active_assumption_ids.length > 0 ? (
        <div className="mt-3 border-t border-[#EEF2F6] pt-3">
          <p className="pb-2 text-xs font-medium uppercase tracking-wider text-[#94A3B8]">
            {ft("forecasts.inspector.assumptions_title")}
          </p>
          <ul className="flex flex-wrap gap-2">
            {payload.active_assumption_ids.map((id) => (
              <li key={id}>
                <button
                  type="button"
                  id={`forecast-inspector-assumption-${id}`}
                  data-testid={`forecast-assumption-link-${id}`}
                  onClick={() => onOpenAssumption?.(id)}
                  disabled={onOpenAssumption === undefined}
                  className="inline-flex rounded-full border border-[#E3E8EF] bg-white px-3 py-1 text-xs font-medium text-[#0F172A] hover:bg-[#F8FAFC] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#6366F1]/40 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {ft("forecasts.inspector.assumption_link", {
                    id: id.slice(0, 8),
                  })}
                </button>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {/* Period issues. */}
      {payload.issues.length > 0 ? (
        <div className="mt-3 border-t border-[#EEF2F6] pt-3">
          <ul className="flex flex-col gap-2">
            {payload.issues.map((issue) => (
              <li
                key={issue.code}
                data-testid={`forecast-period-issue-${issue.code}`}
                className="rounded-lg border border-[#FCD34D] bg-[#FFFBEB] px-3 py-2 text-sm text-[#92400E]"
              >
                {ft(issue.message_key)}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </PanelShell>
  );
}
