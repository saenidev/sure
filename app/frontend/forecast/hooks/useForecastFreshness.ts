// Forecast V2 freshness presentation hook (slice C3).
//
// `useForecastFreshness` is the focused module for the freshness/recompute
// interaction region (spec "Frontend Runtime Modules" -> `useForecastFreshness`:
// "renders stale, recomputing, fresh, failed, and source-limited state
// transitions"). It owns ONE region: turning a `ProjectionFreshness` facet into
// the small derived presentation the `FreshnessIndicator` renders — the
// lifecycle tone, a recompute-in-progress flag, an i18n copy key, and the
// "as of" timestamp.
//
// It is pure derivation from props: no network, no canonical state, no
// ActiveRecord-shaped mutation. The component owns visual markup; this hook owns
// only the state -> presentation mapping so the same lifecycle logic stays in one
// place across the shell badge and any inline indicators.

import { useMemo } from "react";
import type {
  FreshnessLifecycleState,
  ProjectionFreshness,
} from "../types/readModels";

/**
 * The semantic tone each lifecycle state maps to. Tones map to Sure status
 * tokens in the component (never raw palette): `positive` -> success,
 * `attention` -> warning, `critical` -> destructive, `neutral` -> subdued.
 */
export type FreshnessTone = "positive" | "attention" | "critical" | "neutral";

const TONE_BY_STATE: Readonly<Record<FreshnessLifecycleState, FreshnessTone>> =
  {
    fresh: "positive",
    stale: "attention",
    recomputing: "attention",
    "source-limited": "attention",
    failed: "critical",
    superseded: "neutral",
    uncomputed: "neutral",
  };

// The i18n copy key for each lifecycle state. The client localizes these (the
// read models never format the lifecycle label); keys live under
// `forecasts.freshness.*` in config/locales.
const LABEL_KEY_BY_STATE: Readonly<Record<FreshnessLifecycleState, string>> = {
  fresh: "forecasts.freshness.fresh",
  stale: "forecasts.freshness.stale",
  recomputing: "forecasts.freshness.recomputing",
  failed: "forecasts.freshness.failed",
  superseded: "forecasts.freshness.superseded",
  uncomputed: "forecasts.freshness.uncomputed",
  "source-limited": "forecasts.freshness.source_limited",
};

/** The derived, presentation-ready freshness facets. */
export interface ForecastFreshnessView {
  readonly state: FreshnessLifecycleState;
  readonly tone: FreshnessTone;
  /** True while a recompute is in flight (drives the spinner/pulse + aria-busy). */
  readonly isRecomputing: boolean;
  /** True when the projection is the current, trustworthy result. */
  readonly isFresh: boolean;
  /** i18n key for the lifecycle status label. */
  readonly labelKey: string;
  /** ISO-8601 instant the projection was computed, or null before the first. */
  readonly projectedAt: string | null;
}

/**
 * Derives the presentation-ready freshness view from a `ProjectionFreshness`
 * facet. Falls back to the neutral `uncomputed` mapping for any unknown state so
 * an unexpected server value never throws in the indicator.
 */
export function useForecastFreshness(
  freshness: ProjectionFreshness,
): ForecastFreshnessView {
  return useMemo<ForecastFreshnessView>(() => {
    const state = freshness.state;
    return {
      state,
      tone: TONE_BY_STATE[state] ?? "neutral",
      isRecomputing: state === "recomputing",
      isFresh: state === "fresh",
      labelKey: LABEL_KEY_BY_STATE[state] ?? LABEL_KEY_BY_STATE.uncomputed,
      projectedAt: freshness.projected_at,
    };
  }, [freshness]);
}
