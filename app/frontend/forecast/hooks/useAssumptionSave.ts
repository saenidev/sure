// Forecast V2 assumption-editor save flow (slice C8, split out of
// useAssumptionEditor for slice F12).
//
// `useAssumptionSave` owns ONE seam: the typed PATCH save + conflict handling for
// an edited assumption. It is split out of `useAssumptionEditor` so that hook can
// stay focused on drawer lifecycle / focus / dirty state (spec "Frontend module
// responsibility rules": "No module handles both editor lifecycle and recompute
// orchestration"; "Modules over roughly 250 lines require a split"). This hook
// never renders, never owns lifecycle, and never patches the workspace — it drives
// `saveState` / `fieldErrors` / `summaryError` and resolves to the typed
// {@link SaveOutcome} so the caller can patch the workspace (on `saved`) or
// re-anchor the editor (on `conflict`).
//
// Network discipline (spec "Inertia And JSON Endpoints"): a save issues exactly
// one PATCH /forecast/assumptions/:id, echoing the optimistic version tokens (the
// prefill's `lock_version` + the workspace's observed plan version) so the server
// can reject a stale edit (spec "Live Recompute Model", "Conflict Handling").

import { useCallback, useState } from "react";
import type {
  EditorFieldErrors,
  SaveConflict,
  SavedAssumptionPatch,
} from "../types/readModels";

/** Where a save sits in its lifecycle. */
export type EditorSaveState = "idle" | "saving" | "save_error" | "conflict";

/** The outcome the save resolves to, so the caller can patch the workspace. */
export type SaveOutcome =
  | { readonly status: "saved"; readonly patch: SavedAssumptionPatch }
  | { readonly status: "invalid"; readonly fieldErrors: EditorFieldErrors }
  | { readonly status: "conflict"; readonly conflict: SaveConflict }
  | { readonly status: "error" };

/** The form values + version tokens one save submits. */
export interface SaveEditorArgs {
  /** The assumption being saved (family-resolved server-side; opaque). */
  readonly assumptionId: string;
  /** The assumption kind, sent so the server selects the typed form. */
  readonly kind: string;
  /** The edited field values (top-level + form-specific param fields). */
  readonly values: Readonly<Record<string, string>>;
  /**
   * The plan version the workspace observed (owned by the workspace store, passed
   * in here). The server rejects the save with a conflict if the live plan version
   * has moved past it (spec "Live Recompute Model", "Conflict Handling").
   */
  readonly planVersion: number;
}

export interface UseAssumptionSaveArgs {
  /** Builds the save endpoint URL for one assumption id (default: V2 route). */
  readonly buildSaveUrl?: (assumptionId: string) => string;
  /**
   * The optimistic `lock_version` from the loaded prefill, echoed back so the
   * server can reject an edit made against a stale assumption snapshot. `null`
   * when no prefill is loaded (no save is possible).
   */
  readonly lockVersion: number | null;
  /** Marks the form clean after a committed save (owned by the lifecycle hook). */
  readonly onSaved: () => void;
}

export interface UseAssumptionSaveResult {
  /** Where a save sits in its lifecycle. */
  readonly saveState: EditorSaveState;
  /** True while a save is in flight (disables save/cancel). */
  readonly isSaving: boolean;
  /** Field-keyed typed validation errors from a failed save. */
  readonly fieldErrors: EditorFieldErrors;
  /** The top-level summary error code for a failed save, or `null`. */
  readonly summaryError: string | null;

  /**
   * Saves the edited assumption via PATCH /forecast/assumptions/:id, echoing the
   * observed plan version + assumption lock_version for the optimistic checks.
   * Drives `saveState` / `fieldErrors` / `summaryError` and resolves to the typed
   * {@link SaveOutcome} so the caller can patch the workspace (on `saved`) or
   * re-anchor the editor (on `conflict`). It never patches the workspace itself.
   */
  readonly save: (args: SaveEditorArgs) => Promise<SaveOutcome>;
  /** Records the save lifecycle (the caller may drive this directly). */
  readonly setSaveState: (state: EditorSaveState) => void;
  /** Records typed validation errors + optional summary from a failed save. */
  readonly setErrors: (
    fieldErrors: EditorFieldErrors,
    summaryError?: string | null,
  ) => void;
  /** Clears all field + summary errors (e.g. when the editor reopens/resets). */
  readonly clearErrors: () => void;
}

/** The default save endpoint URL for one assumption (spec V2 route shape). */
function defaultBuildSaveUrl(assumptionId: string): string {
  return `/forecast/assumptions/${encodeURIComponent(assumptionId)}`;
}

/** Reads the Rails CSRF token from the page meta tag (rendered by `_head`). */
function csrfToken(): string {
  if (typeof document === "undefined") {
    return "";
  }
  return (
    document
      .querySelector<HTMLMetaElement>('meta[name="csrf-token"]')
      ?.getAttribute("content") ?? ""
  );
}

/**
 * Owns the typed editor save + conflict flow. Drives save lifecycle + typed
 * errors; resolves to the typed outcome so the caller can patch the workspace
 * (saved) or re-anchor (conflict). It never owns drawer lifecycle and never
 * patches the workspace.
 */
export function useAssumptionSave({
  buildSaveUrl = defaultBuildSaveUrl,
  lockVersion,
  onSaved,
}: UseAssumptionSaveArgs): UseAssumptionSaveResult {
  const [saveState, setSaveState] = useState<EditorSaveState>("idle");
  const [fieldErrors, setFieldErrors] = useState<EditorFieldErrors>({});
  const [summaryError, setSummaryError] = useState<string | null>(null);

  const setErrors = useCallback(
    (errors: EditorFieldErrors, summary: string | null = null): void => {
      setFieldErrors(errors);
      setSummaryError(summary);
    },
    [],
  );

  const clearErrors = useCallback((): void => {
    setFieldErrors({});
    setSummaryError(null);
  }, []);

  // Saves the edited assumption. Echoes the optimistic version tokens (the
  // prefill's lock_version + the workspace's observed plan version) so the server
  // can reject a stale edit. Drives save lifecycle + typed errors; resolves to the
  // outcome so the caller can patch the workspace (saved) or re-anchor (conflict).
  const save = useCallback(
    async ({
      assumptionId,
      kind,
      values,
      planVersion,
    }: SaveEditorArgs): Promise<SaveOutcome> => {
      setSaveState("saving");
      setFieldErrors({});
      setSummaryError(null);

      const body = new URLSearchParams();
      body.set("kind", kind);
      body.set("plan_version", String(planVersion));
      if (lockVersion !== undefined && lockVersion !== null) {
        body.set("expected_lock_version", String(lockVersion));
      }
      for (const [name, value] of Object.entries(values)) {
        body.set(name, value);
      }

      try {
        const response = await fetch(buildSaveUrl(assumptionId), {
          method: "PATCH",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "X-CSRF-Token": csrfToken(),
          },
          credentials: "same-origin",
          body: body.toString(),
        });

        if (response.ok) {
          const patch = (await response.json()) as SavedAssumptionPatch;
          setSaveState("idle");
          onSaved();
          return { status: "saved", patch };
        }

        if (response.status === 422) {
          const data = (await response.json()) as {
            errors?: EditorFieldErrors;
          };
          const errors = data.errors ?? {};
          setFieldErrors(errors);
          setSummaryError("invalid");
          setSaveState("save_error");
          return { status: "invalid", fieldErrors: errors };
        }

        if (response.status === 409) {
          const conflict = (await response.json()) as SaveConflict;
          setSummaryError(
            conflict.conflict === "stale_lock_version"
              ? "conflict_lock_version"
              : "conflict_plan_version",
          );
          setSaveState("conflict");
          return { status: "conflict", conflict };
        }

        setSummaryError("save_error");
        setSaveState("save_error");
        return { status: "error" };
      } catch {
        setSummaryError("save_error");
        setSaveState("save_error");
        return { status: "error" };
      }
    },
    [buildSaveUrl, lockVersion, onSaved],
  );

  return {
    saveState,
    isSaving: saveState === "saving",
    fieldErrors,
    summaryError,
    save,
    setSaveState,
    setErrors,
    clearErrors,
  };
}
