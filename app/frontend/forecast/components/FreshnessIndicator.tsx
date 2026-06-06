// Forecast V2 FreshnessIndicator (slice C3).
//
// Renders the projection freshness lifecycle as a compact, accessible pill:
// fresh, stale, recomputing, failed, superseded, uncomputed, and source-limited
// (spec "Forecast Component Contracts" -> `FreshnessIndicator`: "fresh, stale,
// recomputing, failed, and source-limited states"). It is the one place the
// lifecycle is presented, so the shell badge and any inline indicators stay
// visually consistent.
//
// State -> presentation derivation lives in `useForecastFreshness`; this
// component owns only markup. Tokens only — tones map to Sure status tokens
// (text-success / text-warning / text-destructive / text-subdued), never raw
// palette. The pill is non-interactive but announces its state to assistive tech
// (role="status"); while recomputing it sets aria-busy and shows a reduced-motion
// -respecting pulse dot.

import type { JSX } from "react";
import {
  type FreshnessTone,
  useForecastFreshness,
} from "../hooks/useForecastFreshness";
import { ft } from "../i18n";
import type { ProjectionFreshness } from "../types/readModels";

// Tone -> Sure status token classes for the dot + text. No raw palette colors.
const TONE_CLASSES: Readonly<
  Record<FreshnessTone, { dot: string; text: string }>
> = {
  positive: { dot: "bg-success", text: "text-success" },
  attention: { dot: "bg-warning", text: "text-warning" },
  critical: { dot: "bg-destructive", text: "text-destructive" },
  // Neutral (uncomputed / superseded): a muted dot keyed to the subdued text
  // token. There is no dedicated functional bg token for a muted fill, so the dot
  // carries `text-subdued` and fills with `bg-current` — `currentColor` resolves
  // to the subdued ramp (theme-aware light/dark) instead of a raw palette class.
  neutral: { dot: "text-subdued bg-current", text: "text-subdued" },
};

function formatProjectedAt(iso: string): string {
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) {
    return iso;
  }
  return parsed.toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export interface FreshnessIndicatorProps {
  readonly freshness: ProjectionFreshness;
  /** Stable region id for scoped patches / tests. */
  readonly regionKey?: string;
}

export default function FreshnessIndicator({
  freshness,
  regionKey = "forecast-freshness",
}: FreshnessIndicatorProps): JSX.Element {
  const view = useForecastFreshness(freshness);
  const tone = TONE_CLASSES[view.tone];
  const asOf = view.projectedAt
    ? ft("forecasts.workspace.as_of", {
        date: formatProjectedAt(view.projectedAt),
      })
    : ft("forecasts.workspace.not_computed");

  return (
    // <output> has implicit role="status" + aria-live="polite" (the
    // announcement contract the freshness lifecycle needs), which the a11y
    // linter prefers over role="status" on a generic element.
    <output
      data-testid={regionKey}
      data-region={regionKey}
      data-freshness-state={view.state}
      aria-busy={view.isRecomputing}
      className="inline-flex items-center gap-2 rounded-full border border-primary bg-container px-3 py-1 text-sm font-medium"
    >
      <span
        aria-hidden="true"
        className={`size-2 rounded-full ${tone.dot} ${
          view.isRecomputing ? "motion-safe:animate-pulse" : ""
        }`}
      />
      <span className={tone.text}>{ft(view.labelKey)}</span>
      <span className="text-subdued">· {asOf}</span>
    </output>
  );
}
