// Forecast V2 AssumptionGroup (slice C6).
//
// One kind-grouped section of the assumption rail (spec "Forecast Component
// Contracts" -> `AssumptionGroup`: "group header, collapsed/expanded state,
// count/status summaries, and progressive rendering hooks"). It renders the
// localized group header, a count + active-in-period status summary, a
// collapse/expand control, and the group's `AssumptionCard`s — every card payload
// comes preloaded from `AssumptionGroupReadModel`, so there is NO per-card or
// per-group fetch.
//
// State ownership: collapsed/expanded is ephemeral, client-owned interaction
// state local to this region (the server owns canonical plan truth). It uses a
// native <details>/<summary>-style disclosure expressed with a button so the
// open state can be controlled and announced (aria-expanded + a labelled
// region). Tokens only — no raw palette; copy resolves through the client i18n
// table (`ft`).

import { type JSX, useId, useState } from "react";
import { ft } from "../i18n";
import type { AssumptionGroup as AssumptionGroupModel } from "../types/readModels";
import AssumptionCard from "./AssumptionCard";

// Localized "%{count} assumptions" using the explicit one/other keys (the client
// i18n table does no Rails-style pluralization, so the component selects).
function countLabel(count: number): string {
  const key =
    count === 1
      ? "forecasts.assumptions.group_count.one"
      : "forecasts.assumptions.group_count.other";
  return ft(key, { count });
}

export interface AssumptionGroupProps {
  readonly group: AssumptionGroupModel;
  /** Whether the group starts expanded. Groups expand by default. */
  readonly defaultExpanded?: boolean;
  /** Forwarded to each card: opens the type-specific editor (slice C7). */
  readonly onEditCard?: (cardId: string) => void;
  /** Forwarded to each card: runs an overflow action. */
  readonly onCardAction?: (cardId: string, action: string) => void;
}

export default function AssumptionGroup({
  group,
  defaultExpanded = true,
  onEditCard,
  onCardAction,
}: AssumptionGroupProps): JSX.Element {
  const [expanded, setExpanded] = useState(defaultExpanded);
  const bodyId = useId();

  const title = ft(group.title_key);
  const cards = group.cards;
  const activeCount = cards.filter((card) => card.active_in_period).length;
  const toggleLabelKey = expanded
    ? "forecasts.assumptions.collapse"
    : "forecasts.assumptions.expand";

  return (
    <section
      data-testid={`forecast-assumption-group-${group.kind}`}
      data-group-kind={group.kind}
      data-expanded={expanded}
      className="flex flex-col rounded-xl border border-primary bg-surface"
    >
      <button
        type="button"
        data-testid={`forecast-assumption-group-toggle-${group.kind}`}
        aria-expanded={expanded}
        aria-controls={bodyId}
        aria-label={ft(toggleLabelKey, { group: title })}
        onClick={() => setExpanded((open) => !open)}
        className="flex items-center justify-between gap-3 rounded-xl px-4 py-3 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400"
      >
        <span className="flex min-w-0 items-baseline gap-2">
          <span className="truncate text-sm font-semibold text-primary">
            {title}
          </span>
          <span className="shrink-0 text-xs text-subdued tabular-nums">
            {countLabel(cards.length)}
          </span>
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {activeCount > 0 ? (
            <span
              data-testid={`forecast-assumption-group-active-${group.kind}`}
              className="rounded-full bg-success/10 px-2 py-0.5 text-xs font-medium text-success"
            >
              {ft("forecasts.assumptions.active_count", {
                count: activeCount,
              })}
            </span>
          ) : null}
          <span
            aria-hidden="true"
            className={`text-subdued transition-transform ${expanded ? "rotate-180" : ""}`}
          >
            ⌄
          </span>
        </span>
      </button>

      {expanded ? (
        <ul
          id={bodyId}
          data-testid={`forecast-assumption-group-body-${group.kind}`}
          className="flex flex-col gap-3 px-4 pb-4"
        >
          {cards.map((card) => (
            <li key={card.id}>
              <AssumptionCard
                card={card}
                onEdit={onEditCard}
                onAction={onCardAction}
              />
            </li>
          ))}
        </ul>
      ) : null}
    </section>
  );
}
