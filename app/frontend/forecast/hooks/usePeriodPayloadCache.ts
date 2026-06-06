// Forecast V2 selected-period payload cache (slice C5).
//
// `usePeriodPayloadCache` is the ONE focused module for the selected-period read
// region's data lifecycle (spec "Frontend Runtime Modules" -> `usePeriodPayloadCache`:
// "serves selected-period payloads from preloaded data, local cache, or debounced
// JSON fetches after settled selection"). It owns DATA SERVING only — it never
// renders, never persists, never recomputes, and never stores canonical plan
// truth. The SelectedPeriodInspector component renders whatever this hook serves.
//
// Network discipline (spec "Inertia And JSON Endpoints"):
//   - The first-viewport selected period is served from the PRELOADED seed with
//     ZERO network (it arrived in the Inertia props).
//   - A settled selection that is already in the local cache is served with ZERO
//     network.
//   - ONLY a settled selection that misses the cache triggers a DEBOUNCED JSON
//     fetch of GET /forecast/periods/:period_key (SelectedPeriodReadModel).
//   - Pointer hover/scrub never reaches here: the shared workspace store reports
//     SETTLED selections only, so chart scrubbing issues no network by
//     construction.
//
// Cache invalidation: the cache is keyed by the region cache key (plan version +
// scenario stack). When that key changes (a recompute published a new
// projection), the cache resets so stale period payloads can never be served for
// a newer plan version.

import { useCallback, useEffect, useRef, useState } from "react";
import type { PeriodKey, SelectedPeriodReadModel } from "../types/readModels";

/** How long a settled cache-miss selection waits before issuing the JSON fetch. */
const DEFAULT_DEBOUNCE_MS = 180;

/** The data-serving status the inspector renders around. */
export type PeriodPayloadStatus = "idle" | "loading" | "ready" | "error";

export interface UsePeriodPayloadCacheArgs {
  /**
   * The currently selected period from the shared workspace store. This updates
   * ONLY on a settled selection (keyboard/click), never on hover/scrub, so the
   * hook never fetches during pointer movement.
   */
  readonly selectedPeriodKey: PeriodKey | null;
  /**
   * The preloaded first-viewport selected-period payload from the Inertia props
   * (`null` before any period is projected). Seeds the cache so the default
   * period renders with zero network.
   */
  readonly seed: SelectedPeriodReadModel | null;
  /**
   * The region cache key (plan version + scenario stack). When it changes the
   * cache resets, so a recompute invalidates every cached period payload.
   */
  readonly cacheKey: string;
  /** Builds the JSON endpoint URL for one period key (default: the V2 route). */
  readonly buildUrl?: (periodKey: PeriodKey) => string;
  /** Debounce window before a settled cache-miss fetch (ms). */
  readonly debounceMs?: number;
}

export interface UsePeriodPayloadCacheResult {
  /** The payload for the current selection (seed, cache, or fetched); null when none. */
  readonly payload: SelectedPeriodReadModel | null;
  /** Where the current selection sits in the data-serving lifecycle. */
  readonly status: PeriodPayloadStatus;
  /** True while a debounced fetch for the current selection is in flight. */
  readonly isFetching: boolean;
  /** Forces a refresh of the current selection (explicit refresh path). */
  readonly refresh: () => void;
}

/** The default JSON endpoint URL for one period key (spec V2 route shape). */
function defaultBuildUrl(periodKey: PeriodKey): string {
  return `/forecast/periods/${encodeURIComponent(periodKey)}`;
}

/**
 * Serves the selected-period payload from the preloaded seed, a local cache, or a
 * debounced JSON fetch on a settled cache miss. Returns the payload plus the
 * data-serving status the inspector renders around.
 */
export function usePeriodPayloadCache({
  selectedPeriodKey,
  seed,
  cacheKey,
  buildUrl = defaultBuildUrl,
  debounceMs = DEFAULT_DEBOUNCE_MS,
}: UsePeriodPayloadCacheArgs): UsePeriodPayloadCacheResult {
  // The local period -> payload cache. A ref (not state) because mutating it
  // must not itself trigger a render; renders are driven by `payload`/`status`.
  const cacheRef = useRef<Map<PeriodKey, SelectedPeriodReadModel>>(new Map());
  // The cache-key generation this cache belongs to; a change resets the cache.
  const cacheGenerationRef = useRef<string>(cacheKey);
  // Monotonic token so an out-of-order fetch response can be ignored.
  const requestTokenRef = useRef(0);

  const [payload, setPayload] = useState<SelectedPeriodReadModel | null>(seed);
  const [status, setStatus] = useState<PeriodPayloadStatus>(
    seed ? "ready" : "idle",
  );

  // Seed the cache (and re-seed on cache-key change) so the default period and
  // every projection-update reseed render with zero network.
  if (cacheGenerationRef.current !== cacheKey) {
    cacheGenerationRef.current = cacheKey;
    cacheRef.current = new Map();
  }
  if (seed && !cacheRef.current.has(seed.period_key)) {
    cacheRef.current.set(seed.period_key, seed);
  }

  // Serves a period from the local cache when present. Re-created per cache-key
  // generation so the selection effect re-runs after a recompute reset (the new
  // generation's cache is empty, so the same selected period re-serves/re-fetches
  // fresh detail rather than showing a stale payload). `cacheKey` is the
  // generation token; it intentionally drives identity, not the body.
  const serveFromCache = useCallback(
    (key: PeriodKey): boolean => {
      void cacheKey;
      const cached = cacheRef.current.get(key);
      if (cached) {
        setPayload(cached);
        setStatus("ready");
        return true;
      }
      return false;
    },
    [cacheKey],
  );

  const fetchPeriod = useCallback(
    (key: PeriodKey, signal: AbortSignal): void => {
      const token = ++requestTokenRef.current;
      setStatus("loading");
      fetch(buildUrl(key), {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal,
      })
        .then((response) => {
          if (!response.ok) {
            throw new Error(
              `period payload request failed: ${response.status}`,
            );
          }
          return response.json() as Promise<SelectedPeriodReadModel>;
        })
        .then((data) => {
          // Ignore stale responses (the selection moved on, or a newer
          // projection generation reset the cache while this was in flight).
          if (token !== requestTokenRef.current) {
            return;
          }
          cacheRef.current.set(key, data);
          setPayload(data);
          setStatus("ready");
        })
        .catch((error: unknown) => {
          if (signal.aborted || token !== requestTokenRef.current) {
            return;
          }
          if (error instanceof DOMException && error.name === "AbortError") {
            return;
          }
          setStatus("error");
        });
    },
    [buildUrl],
  );

  // React to a SETTLED selection. Cache hits serve immediately (no network);
  // misses debounce, then fetch. Cleanup aborts any in-flight/pending fetch so a
  // rapid settled-selection change never races.
  useEffect(() => {
    if (selectedPeriodKey === null) {
      setPayload(null);
      setStatus("idle");
      return;
    }

    if (serveFromCache(selectedPeriodKey)) {
      return;
    }

    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      fetchPeriod(selectedPeriodKey, controller.signal);
    }, debounceMs);

    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
    // `serveFromCache` is re-created per cache-key generation, so this effect
    // re-runs after a recompute reset without naming `cacheKey` directly.
  }, [selectedPeriodKey, debounceMs, serveFromCache, fetchPeriod]);

  const refresh = useCallback(() => {
    if (selectedPeriodKey === null) {
      return;
    }
    cacheRef.current.delete(selectedPeriodKey);
    const controller = new AbortController();
    fetchPeriod(selectedPeriodKey, controller.signal);
  }, [selectedPeriodKey, fetchPeriod]);

  return {
    payload,
    status,
    isFetching: status === "loading",
    refresh,
  };
}
