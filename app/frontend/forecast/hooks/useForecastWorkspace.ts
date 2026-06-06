// Forecast V2 shared workspace store (slice C3).
//
// `useForecastWorkspace` is the ONE small, colocated reducer the Forecast V2
// workspace shares (spec "Frontend Runtime Modules" -> `useForecastWorkspace`,
// "Frontend module responsibility rules" -> "Shared state must be colocated in a
// small workspace store or reducer. Do not introduce a global app store"). It
// owns ONLY ephemeral client interaction state plus the server-issued version
// tokens / region cache keys needed to scope later partial reloads and JSON
// patches:
//
//   - selectedPeriodKey  : the period the inspector + chart marker track.
//   - selectedMetric     : the metric the band chart + strip track.
//   - activeLens         : the open lens tab.
//   - scenarioStackKey   : the live scenario-stack key the projection reflects.
//   - freshness          : the current projection freshness facet (shell badge).
//   - planVersion        : the optimistic version token for scoped recompute.
//   - regionCacheKeys    : stable per-region cache keys for scoped patches.
//
// The server still owns canonical plan truth; this store NEVER stores financial
// records, never mutates the server, and never parses engine result internals.
// It is seeded from the typed first-viewport props and is the only place the
// shell, chart, strip, and inspector read shared selection from.

import { useMemo, useReducer } from "react";
import type {
  ForecastWorkspaceProps,
  FreshnessLifecycleState,
  PeriodKey,
  ProjectionFreshness,
  SavedAssumptionPatch,
} from "../types/readModels";

/**
 * The stable region keys the workspace patches in isolation. They double as
 * `data-testid` region anchors on the shell so a scoped prop reload / JSON patch
 * can target exactly one region without CSS-selector coupling (spec: "stable
 * `data-testid`/region keys rather than relying on CSS selectors").
 */
export const FORECAST_REGIONS = {
  shell: "forecast-plan-shell",
  metricStrip: "forecast-metric-strip",
  freshness: "forecast-freshness",
  chart: "forecast-projection-chart",
  inspector: "forecast-selected-period",
  assumptions: "forecast-assumption-groups",
  issues: "forecast-issue-panel",
} as const;

export type ForecastRegion = keyof typeof FORECAST_REGIONS;

/** Stable cache key per patchable region, keyed by the live plan version. */
export type RegionCacheKeys = Readonly<Record<ForecastRegion, string>>;

/** The shared, ephemeral workspace state. Plan truth stays on the server. */
export interface ForecastWorkspaceState {
  readonly selectedPeriodKey: PeriodKey | null;
  readonly selectedMetric: string;
  readonly activeLens: string;
  readonly scenarioStackKey: string;
  readonly freshness: ProjectionFreshness;
  readonly planVersion: number;
  readonly regionCacheKeys: RegionCacheKeys;
}

/**
 * The actions the workspace dispatches. All are local interaction-state changes
 * except `projectionUpdated`, which folds a server-issued projection update
 * (new version token + freshness + scenario stack) into the store so dependent
 * regions can recompute their cache keys (spec workspace event contract:
 * `forecast:projection-updated`).
 */
export type ForecastWorkspaceAction =
  | { type: "selectPeriod"; periodKey: PeriodKey | null }
  | { type: "selectMetric"; metric: string }
  | { type: "setLens"; lens: string }
  | {
      type: "projectionUpdated";
      planVersion: number;
      scenarioStackKey: string;
      freshness: ProjectionFreshness;
    }
  | { type: "setFreshnessState"; state: FreshnessLifecycleState };

// Compute the region cache keys for a given plan version + scenario stack. Each
// region key is stable while the plan version and stack are unchanged, so a
// region only re-fetches/patches when the projection it depends on changes.
function computeRegionCacheKeys(
  planVersion: number,
  scenarioStackKey: string,
): RegionCacheKeys {
  const suffix = `${scenarioStackKey}:v${planVersion}`;
  return {
    shell: `${FORECAST_REGIONS.shell}:${suffix}`,
    metricStrip: `${FORECAST_REGIONS.metricStrip}:${suffix}`,
    freshness: `${FORECAST_REGIONS.freshness}:${suffix}`,
    chart: `${FORECAST_REGIONS.chart}:${suffix}`,
    inspector: `${FORECAST_REGIONS.inspector}:${suffix}`,
    assumptions: `${FORECAST_REGIONS.assumptions}:${suffix}`,
    issues: `${FORECAST_REGIONS.issues}:${suffix}`,
  };
}

function reducer(
  state: ForecastWorkspaceState,
  action: ForecastWorkspaceAction,
): ForecastWorkspaceState {
  switch (action.type) {
    case "selectPeriod":
      if (action.periodKey === state.selectedPeriodKey) {
        return state;
      }
      return { ...state, selectedPeriodKey: action.periodKey };
    case "selectMetric":
      if (action.metric === state.selectedMetric) {
        return state;
      }
      return { ...state, selectedMetric: action.metric };
    case "setLens":
      if (action.lens === state.activeLens) {
        return state;
      }
      return { ...state, activeLens: action.lens };
    case "projectionUpdated":
      return {
        ...state,
        planVersion: action.planVersion,
        scenarioStackKey: action.scenarioStackKey,
        freshness: action.freshness,
        regionCacheKeys: computeRegionCacheKeys(
          action.planVersion,
          action.scenarioStackKey,
        ),
      };
    case "setFreshnessState":
      if (action.state === state.freshness.state) {
        return state;
      }
      return {
        ...state,
        freshness: { ...state.freshness, state: action.state },
      };
    default:
      return state;
  }
}

// Derive the initial shared state from the typed first-viewport props. The
// selected period seeds from the band's selected marker (which matches the
// seeded selected-period read model in C2).
function initFromProps(props: ForecastWorkspaceProps): ForecastWorkspaceState {
  const planVersion = props.plan.plan_version;
  const scenarioStackKey = props.plan.scenario_stack.key;
  return {
    selectedPeriodKey:
      props.selectedPeriod?.period_key ?? props.band.selected_marker ?? null,
    selectedMetric: props.band.selected_metric,
    activeLens: props.plan.active_lens,
    scenarioStackKey,
    freshness: props.freshness,
    planVersion,
    regionCacheKeys: computeRegionCacheKeys(planVersion, scenarioStackKey),
  };
}

/** The public store handle the workspace components share. */
export interface ForecastWorkspaceStore extends ForecastWorkspaceState {
  readonly selectPeriod: (periodKey: PeriodKey | null) => void;
  readonly selectMetric: (metric: string) => void;
  readonly setLens: (lens: string) => void;
  readonly applyProjectionUpdate: (update: {
    planVersion: number;
    scenarioStackKey: string;
    freshness: ProjectionFreshness;
  }) => void;
  /**
   * Folds a committed assumption save's typed changed-region patch (slice C8) into
   * the store: the new plan version + scenario stack + freshness, which recompute
   * the region cache keys so each scoped region re-fetches/patches in isolation
   * (spec "Patch budget": a save patches scoped regions, never the whole tree).
   * The shared store only tracks version tokens + freshness; the saved card,
   * inspector, metric strip, and issue regions read their own slices of the patch.
   */
  readonly applyAssumptionPatch: (patch: SavedAssumptionPatch) => void;
  readonly setFreshnessState: (state: FreshnessLifecycleState) => void;
}

/**
 * Owns the shared, ephemeral Forecast V2 workspace state. Pass the typed
 * first-viewport props; the store seeds from them and exposes the small set of
 * selection + projection-update actions the shell, chart, strip, and inspector
 * dispatch.
 */
export function useForecastWorkspace(
  props: ForecastWorkspaceProps,
): ForecastWorkspaceStore {
  const [state, dispatch] = useReducer(reducer, props, initFromProps);

  return useMemo<ForecastWorkspaceStore>(
    () => ({
      ...state,
      selectPeriod: (periodKey) =>
        dispatch({ type: "selectPeriod", periodKey }),
      selectMetric: (metric) => dispatch({ type: "selectMetric", metric }),
      setLens: (lens) => dispatch({ type: "setLens", lens }),
      applyProjectionUpdate: (update) =>
        dispatch({ type: "projectionUpdated", ...update }),
      applyAssumptionPatch: (patch) =>
        dispatch({
          type: "projectionUpdated",
          planVersion: patch.version_tokens.plan_version,
          scenarioStackKey: patch.version_tokens.scenario_stack_key,
          freshness: patch.freshness,
        }),
      setFreshnessState: (freshnessState) =>
        dispatch({ type: "setFreshnessState", state: freshnessState }),
    }),
    [state],
  );
}
