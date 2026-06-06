// Forecast V2 AssumptionCard (slice C6).
//
// A dense, scannable assumption summary (spec "Forecast Component Contracts" ->
// `AssumptionCard`: "dense assumption summary, provenance, active-in-period
// state, issue badges, and actions"; spec "Assumption Card Anatomy"). It reads
// EVERY field from the preloaded card payload that `AssumptionGroupReadModel`
// serialized — there is NO per-card fetch and NO engine call from the client.
//
// Card copy contract (spec "Assumption Card Anatomy"): cards must read like
// financial-planning language, e.g. "Salary: $9,500/mo until retirement, 3%
// annual growth" — not "Event #12, recurring, amount effect, active". The read
// model never formats UI strings: it hands the client structured summaries
// (decimal-string amounts + i18n keys + raw timing/behavior fields) and this
// component composes them into a primary amount/time line and a compact
// secondary line.
//
// Stable height bands (spec "Component tests ... must cover dense, sparse,
// long-label ... states"): the card reserves fixed-height rows for the title,
// primary line, and secondary line so a sparse card and a dense card occupy the
// same vertical rhythm and the rail never reflows when summaries differ.
//
// Tokens only — no raw palette. Money cells carry `privacy-sensitive` so the
// app-wide privacy-mode toggle blurs them with no forecast-specific JS. Copy
// resolves through the client i18n table (`ft`); the icon is an inline glyph
// (no `lucide_icon`, no network) chosen from the read model's icon name.

import { type JSX, useId, useState } from "react";
import { ft } from "../i18n";
import type {
  AssumptionCard as AssumptionCardModel,
  AssumptionCardSummary,
} from "../types/readModels";

// Inline glyph per assumption-rail icon name (matching the read model's
// `ICON_FOR_KIND`). Inline SVG over `lucide_icon` keeps the React island free of
// the Rails icon helper and ships zero extra network. Falls back to a neutral
// dot for unknown kinds.
function CardGlyph({ name }: { readonly name: string }): JSX.Element {
  // `aria-hidden` is set literally on each <svg> (not via a spread) so the
  // markup matches the established ForecastPlanShell glyph pattern and the
  // a11y linter can see the glyph is decorative.
  const common = {
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 2,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    className: "size-4",
  };
  if (name === "briefcase") {
    return (
      <svg aria-hidden="true" {...common}>
        <rect x="2" y="7" width="20" height="14" rx="2" />
        <path d="M8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
      </svg>
    );
  }
  if (name === "shopping-cart") {
    return (
      <svg aria-hidden="true" {...common}>
        <circle cx="9" cy="21" r="1" />
        <circle cx="20" cy="21" r="1" />
        <path d="M1 1h4l2.7 13.4a2 2 0 0 0 2 1.6h9.7a2 2 0 0 0 2-1.6L23 6H6" />
      </svg>
    );
  }
  return (
    <svg aria-hidden="true" {...common}>
      <circle cx="12" cy="12" r="9" />
    </svg>
  );
}

// Map a raw frequency token to the localized amount-per phrase. Defaults to a
// monthly cadence (the dominant assumption shape) when frequency is absent.
const FREQUENCY_KEY: Readonly<Record<string, string>> = {
  monthly: "forecasts.cards.amount_per.month",
  month: "forecasts.cards.amount_per.month",
  annual: "forecasts.cards.amount_per.year",
  yearly: "forecasts.cards.amount_per.year",
  year: "forecasts.cards.amount_per.year",
  weekly: "forecasts.cards.amount_per.week",
  week: "forecasts.cards.amount_per.week",
  quarterly: "forecasts.cards.amount_per.quarter",
  quarter: "forecasts.cards.amount_per.quarter",
  one_time: "forecasts.cards.amount_per.one_time",
  once: "forecasts.cards.amount_per.one_time",
};

// Format a canonical decimal-string amount for display. The decimal string stays
// the source of truth; this never feeds a float back into financial logic.
function formatAmount(amount: string | null | undefined): string | null {
  if (amount === null || amount === undefined || amount === "") {
    return null;
  }
  const parsed = Number.parseFloat(amount);
  if (Number.isNaN(parsed)) {
    return amount;
  }
  return new Intl.NumberFormat(undefined, {
    maximumFractionDigits: 0,
  }).format(parsed);
}

// Format a raw rate (e.g. "0.03" or "3") as a percentage. Values <= 1 are read
// as fractions; larger values are read as already-percent.
function formatRate(rate: string | null | undefined): string | null {
  if (rate === null || rate === undefined || rate === "") {
    return null;
  }
  const parsed = Number.parseFloat(rate);
  if (Number.isNaN(parsed)) {
    return null;
  }
  const percent = parsed <= 1 ? parsed * 100 : parsed;
  return `${new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(percent)}%`;
}

// Format an ISO date (YYYY-MM-DD) into a short month-year anchor ("Aug 2026").
function formatAnchor(iso: string | null | undefined): string | null {
  if (iso === null || iso === undefined || iso === "") {
    return null;
  }
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) {
    return iso;
  }
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    year: "numeric",
  }).format(parsed);
}

// Compose the primary amount line ("$9,500/mo until retirement, 3% annual
// growth"): amount + cadence + time range + the leading behavior fact. This is
// the financial-planning headline the card copy contract requires.
function primaryLine(card: AssumptionCardModel): string {
  const amount = formatAmount(card.amount_summary.amount);
  const frequency = card.amount_summary.frequency ?? "monthly";
  const amountPhrase =
    amount === null
      ? ft("forecasts.cards.amount_unknown")
      : ft(FREQUENCY_KEY[frequency] ?? "forecasts.cards.amount_per.month", {
          amount,
        });

  const parts = [amountPhrase];
  const time = timePhrase(card.time_summary);
  if (time !== null) {
    parts.push(time);
  }
  return parts.join(", ");
}

// "from Aug 2026 until Mar 2028" / "until retirement" / "ongoing".
function timePhrase(summary: AssumptionCardSummary): string | null {
  const start = formatAnchor(summary.starts_on);
  const end = formatAnchor(summary.ends_on);
  if (start !== null && end !== null) {
    return ft("forecasts.cards.time_from_until", { start, end });
  }
  if (start !== null) {
    return ft("forecasts.cards.time_from", { start });
  }
  if (end !== null) {
    return ft("forecasts.cards.time_until", { end });
  }
  return ft("forecasts.cards.time_ongoing");
}

// Compose the compact secondary line from behavior + source facts: growth,
// inflation-linking, and "derived from your data". Falls back to a stable
// no-detail line so the row keeps its height band when there is nothing to say.
function secondaryLine(card: AssumptionCardModel): string {
  const facts: string[] = [];
  const growth = formatRate(card.behavior_summary.growth_rate);
  if (growth !== null) {
    facts.push(ft("forecasts.cards.growth_annual", { rate: growth }));
  }
  if (
    card.behavior_summary.inflation_rate !== null &&
    card.behavior_summary.inflation_rate !== undefined &&
    card.behavior_summary.inflation_rate !== ""
  ) {
    facts.push(ft("forecasts.cards.inflation_linked"));
  }
  if (card.source_summary.origin === "source_derived") {
    facts.push(ft("forecasts.cards.source_derived"));
  }
  if (facts.length === 0) {
    return ft("forecasts.cards.no_secondary");
  }
  return facts.join(" · ");
}

// Status / provenance badge tone. Issue + review badges draw attention; disabled
// is muted; derived/low-confidence/scenario are neutral context.
const BADGE_CLASS: Readonly<Record<string, string>> = {
  issue: "border-warning text-warning",
  review_suggested: "border-warning text-warning",
  disabled: "border-primary text-subdued",
  scenario: "border-primary text-secondary",
  derived: "border-primary text-secondary",
  low_confidence: "border-primary text-secondary",
};

function badgeClass(code: string): string {
  return BADGE_CLASS[code] ?? "border-primary text-secondary";
}

// Action -> localized label for the edit button and the overflow menu.
const ACTION_LABEL_KEY: Readonly<Record<string, string>> = {
  edit: "forecasts.assumptions.action_edit",
  duplicate: "forecasts.assumptions.action_duplicate",
  move_to_scenario: "forecasts.assumptions.action_move_to_scenario",
  disable: "forecasts.assumptions.action_disable",
  archive: "forecasts.assumptions.action_archive",
  delete: "forecasts.assumptions.action_delete",
};

function actionLabel(action: string): string {
  return ft(ACTION_LABEL_KEY[action] ?? "forecasts.assumptions.action_edit");
}

export interface AssumptionCardProps {
  readonly card: AssumptionCardModel;
  /**
   * Opens the type-specific editor for this card. Wired by slice C7; until then
   * the card links to the edit endpoint as a progressive-enhancement fallback.
   */
  readonly onEdit?: (cardId: string) => void;
  /** Runs an overflow action (duplicate / move-to-scenario / …). */
  readonly onAction?: (cardId: string, action: string) => void;
}

export default function AssumptionCard({
  card,
  onEdit,
  onAction,
}: AssumptionCardProps): JSX.Element {
  const [menuOpen, setMenuOpen] = useState(false);
  const menuId = useId();

  // Edit is rendered as a dedicated control; the rest fall into the overflow.
  const overflowActions = card.actions.filter((action) => action !== "edit");
  const canEdit = card.actions.includes("edit");

  const handleEdit = (): void => {
    onEdit?.(card.id);
  };

  const handleAction = (action: string): void => {
    setMenuOpen(false);
    onAction?.(card.id, action);
  };

  return (
    <article
      data-testid={`forecast-assumption-card-${card.id}`}
      data-card-kind={card.kind}
      data-active-in-period={card.active_in_period}
      className="flex items-start gap-3 rounded-xl border border-primary bg-container p-4"
    >
      <span className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-lg border border-primary bg-surface-inset text-secondary">
        <CardGlyph name={card.icon} />
      </span>

      <div className="flex min-w-0 flex-1 flex-col gap-1.5">
        {/* Title row: type label + name, plus the active-in-period marker. The
				    row holds a fixed height so dense/sparse cards align. */}
        <div className="flex min-h-5 items-center justify-between gap-2">
          <h4 className="truncate text-sm font-semibold text-primary">
            {card.title}
          </h4>
          {card.active_in_period ? (
            <span
              data-testid={`forecast-assumption-active-${card.id}`}
              className="shrink-0 rounded-full bg-success/10 px-2 py-0.5 text-xs font-medium text-success"
            >
              {ft("forecasts.assumptions.active_in_period")}
            </span>
          ) : null}
        </div>

        {/* Primary financial-planning line (amount + cadence + time range). */}
        <p className="privacy-sensitive min-h-5 truncate text-sm text-primary">
          {primaryLine(card)}
        </p>

        {/* Compact secondary facts (growth, inflation, provenance). */}
        <p className="min-h-4 truncate text-xs text-subdued">
          {secondaryLine(card)}
        </p>

        {/* Provenance / review / issue badges (privacy-safe codes only). */}
        {card.status_badges.length > 0 ? (
          <ul className="flex min-h-5 flex-wrap items-center gap-1.5">
            {card.status_badges.map((code) => (
              <li
                key={code}
                data-testid={`forecast-assumption-badge-${code}`}
                className={`rounded-full border px-2 py-0.5 text-xs font-medium ${badgeClass(code)}`}
              >
                {ft(`forecasts.badges.${code}`)}
              </li>
            ))}
          </ul>
        ) : (
          <div className="min-h-5" aria-hidden="true" />
        )}
      </div>

      {/* Edit + overflow actions. Edit is the primary affordance; the overflow
			    holds duplicate / move-to-scenario / disable / archive / delete. */}
      <div className="relative flex shrink-0 items-center gap-1">
        {canEdit ? (
          <button
            type="button"
            data-testid={`forecast-assumption-edit-${card.id}`}
            onClick={handleEdit}
            className="rounded-lg border border-primary px-2.5 py-1 text-xs font-medium text-primary hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400"
          >
            {ft("forecasts.assumptions.edit")}
          </button>
        ) : null}

        {overflowActions.length > 0 ? (
          <>
            <button
              type="button"
              data-testid={`forecast-assumption-overflow-${card.id}`}
              aria-haspopup="menu"
              aria-expanded={menuOpen}
              aria-controls={menuId}
              aria-label={ft("forecasts.assumptions.more_actions")}
              onClick={() => setMenuOpen((open) => !open)}
              className="flex size-7 items-center justify-center rounded-lg border border-primary text-secondary hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400"
            >
              <span aria-hidden="true" className="text-base leading-none">
                ⋯
              </span>
            </button>
            {menuOpen ? (
              <ul
                id={menuId}
                role="menu"
                className="absolute right-0 top-9 z-10 flex min-w-40 flex-col rounded-lg border border-primary bg-container p-1 shadow-md"
              >
                {overflowActions.map((action) => (
                  <li key={action}>
                    <button
                      type="button"
                      role="menuitem"
                      data-testid={`forecast-assumption-action-${card.id}-${action}`}
                      onClick={() => handleAction(action)}
                      className="w-full rounded-md px-3 py-1.5 text-left text-sm text-primary hover:bg-surface"
                    >
                      {actionLabel(action)}
                    </button>
                  </li>
                ))}
              </ul>
            ) : null}
          </>
        ) : null}
      </div>
    </article>
  );
}
