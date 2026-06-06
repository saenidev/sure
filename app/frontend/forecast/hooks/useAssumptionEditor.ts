// Forecast V2 assumption-editor drawer lifecycle (slice C7).
//
// `useAssumptionEditor` is the ONE focused module for the typed editor drawer's
// lifecycle (spec "Frontend Runtime Modules" -> `useAssumptionEditor`: "handles
// drawer/modal lifecycle, focus management, dirty state, pending save state, typed
// validation errors, and optimistic version tokens"). It owns DRAWER STATE only —
// it never renders, never persists canonical plan truth, and never orchestrates
// recompute (spec "Frontend module responsibility rules": "No module handles both
// editor lifecycle and recompute orchestration"). The save itself lands in C8;
// this hook exposes the seams (`pendingSave`, `setFieldErrors`, version token) the
// save wires into.
//
// Network discipline (spec "Inertia And JSON Endpoints"): opening the drawer
// fetches GET /forecast/assumptions/:id/edit ONCE for the EditorPrefillReadModel
// (B13) typed payload — never a full plan payload. Closing issues no network.
// The fetched `lock_version` is the optimistic version token a later save sends
// back so a stale edit is rejected (spec "Form Objects": "stale lock/version
// conflicts").
//
// Context preservation (spec "Editor Contracts": "Preserve plan, scenario stack,
// lens, and selected period"): this hook deliberately owns NONE of plan / period
// / scenario state — that all lives in the shared workspace store
// (useForecastWorkspace), which the drawer renders over. Opening/closing the
// drawer therefore cannot disturb the selected period or scenario stack. The hook
// only records which control invoked the open so focus can return to it on close
// (spec "Editor Contracts": "Return focus to the opening control after close").

import { useCallback, useEffect, useRef, useState } from "react";
import type {
	EditorFieldErrors,
	EditorPrefillReadModel,
	SaveConflict,
	SavedAssumptionPatch,
} from "../types/readModels";

/** Where the drawer sits in its open/load lifecycle. */
export type EditorLifecycle =
	| "closed"
	| "loading"
	| "ready"
	| "load_error";

/** Where a save sits in its lifecycle. */
export type EditorSaveState = "idle" | "saving" | "save_error" | "conflict";

/** The outcome the save resolves to, so the caller can patch the workspace. */
export type SaveOutcome =
	| { readonly status: "saved"; readonly patch: SavedAssumptionPatch }
	| { readonly status: "invalid"; readonly fieldErrors: EditorFieldErrors }
	| { readonly status: "conflict"; readonly conflict: SaveConflict }
	| { readonly status: "error" };

export interface UseAssumptionEditorArgs {
	/** Builds the editor-open endpoint URL for one assumption id (default: V2 route). */
	readonly buildUrl?: (assumptionId: string) => string;
	/** Builds the save endpoint URL for one assumption id (default: V2 route). */
	readonly buildSaveUrl?: (assumptionId: string) => string;
}

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

export interface OpenEditorArgs {
	/** The assumption to edit (family-resolved server-side; opaque to the client). */
	readonly assumptionId: string;
	/**
	 * The DOM id / ref of the control that invoked the open, so focus returns to it
	 * on close (spec "Editor Contracts"). Optional — falls back to the previously
	 * focused element captured at open time.
	 */
	readonly invokerId?: string;
}

export interface UseAssumptionEditorResult {
	/** True while the drawer is mounted (any non-closed lifecycle state). */
	readonly isOpen: boolean;
	/** The drawer's open/load lifecycle state. */
	readonly lifecycle: EditorLifecycle;
	/** The fetched typed editor payload, or `null` until it loads. */
	readonly prefill: EditorPrefillReadModel | null;
	/** Whether the form has unsaved edits (drives the dirty-state warning). */
	readonly isDirty: boolean;
	/** Where a save sits in its lifecycle. */
	readonly saveState: EditorSaveState;
	/** True while a save is in flight (disables save/cancel). */
	readonly isSaving: boolean;
	/** Field-keyed typed validation errors from a failed save (C8). */
	readonly fieldErrors: EditorFieldErrors;
	/** The top-level summary error code for a failed save, or `null`. */
	readonly summaryError: string | null;
	/** The optimistic version token (lock_version) a save must echo back. */
	readonly versionToken: number | null;
	/** The id of the control to return focus to on close. */
	readonly invokerId: string | null;

	/** Opens the drawer for one assumption, fetching its editor prefill once. */
	readonly open: (args: OpenEditorArgs) => void;
	/**
	 * Saves the edited assumption via PATCH /forecast/assumptions/:id, echoing the
	 * observed plan version + assumption lock_version for the optimistic checks.
	 * Drives `saveState` / `fieldErrors` / `summaryError` and resolves to the typed
	 * {@link SaveOutcome} so the caller can patch the workspace (on `saved`) or
	 * re-anchor the editor (on `conflict`). It never patches the workspace itself —
	 * editor lifecycle and recompute orchestration stay separate (spec "Frontend
	 * module responsibility rules").
	 */
	readonly save: (args: SaveEditorArgs) => Promise<SaveOutcome>;
	/**
	 * Requests a close. Returns `true` if the drawer closed; `false` if it was
	 * blocked because there are unsaved edits and `force` was not passed (the
	 * caller should surface the dirty-state warning, then call again with `force`).
	 */
	readonly requestClose: (force?: boolean) => boolean;
	/** Marks the form dirty/clean (the form view reports edits). */
	readonly setDirty: (dirty: boolean) => void;
	/** Records the save lifecycle (the save flow in C8 drives this). */
	readonly setSaveState: (state: EditorSaveState) => void;
	/** Records typed validation errors + optional summary from a failed save. */
	readonly setErrors: (
		fieldErrors: EditorFieldErrors,
		summaryError?: string | null,
	) => void;
	/** Clears all field + summary errors (e.g. when the user edits a bad field). */
	readonly clearErrors: () => void;
}

/** The default editor-open endpoint URL for one assumption (spec V2 route shape). */
function defaultBuildUrl(assumptionId: string): string {
	return `/forecast/assumptions/${encodeURIComponent(assumptionId)}/edit`;
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
 * Owns the typed editor drawer's lifecycle, dirty state, pending save state,
 * typed validation errors, and the optimistic version token. Plan / period /
 * scenario context is intentionally NOT owned here — it lives in the shared
 * workspace store, so opening or closing the drawer preserves it.
 */
export function useAssumptionEditor({
	buildUrl = defaultBuildUrl,
	buildSaveUrl = defaultBuildSaveUrl,
}: UseAssumptionEditorArgs = {}): UseAssumptionEditorResult {
	const [lifecycle, setLifecycle] = useState<EditorLifecycle>("closed");
	const [prefill, setPrefill] = useState<EditorPrefillReadModel | null>(null);
	const [isDirty, setIsDirty] = useState(false);
	const [saveState, setSaveState] = useState<EditorSaveState>("idle");
	const [fieldErrors, setFieldErrors] = useState<EditorFieldErrors>({});
	const [summaryError, setSummaryError] = useState<string | null>(null);
	const [invokerId, setInvokerId] = useState<string | null>(null);

	// Monotonic open token so a stale fetch (the user opened a different card while
	// the first was still loading) is ignored.
	const openTokenRef = useRef(0);
	// The element to restore focus to on close, captured at open time when no
	// explicit invoker id was passed (spec "Editor Contracts": return focus).
	const restoreFocusRef = useRef<HTMLElement | null>(null);

	const resetEditorState = useCallback(() => {
		setPrefill(null);
		setIsDirty(false);
		setSaveState("idle");
		setFieldErrors({});
		setSummaryError(null);
	}, []);

	const open = useCallback(
		({ assumptionId, invokerId: invoker }: OpenEditorArgs): void => {
			const token = ++openTokenRef.current;
			restoreFocusRef.current =
				typeof document !== "undefined"
					? (document.activeElement as HTMLElement | null)
					: null;
			setInvokerId(invoker ?? null);
			resetEditorState();
			setLifecycle("loading");

			fetch(buildUrl(assumptionId), {
				headers: { Accept: "application/json" },
				credentials: "same-origin",
			})
				.then((response) => {
					if (!response.ok) {
						throw new Error(`editor prefill request failed: ${response.status}`);
					}
					return response.json() as Promise<EditorPrefillReadModel>;
				})
				.then((data) => {
					// Ignore a stale response (a newer open superseded this fetch).
					if (token !== openTokenRef.current) {
						return;
					}
					setPrefill(data);
					setLifecycle("ready");
				})
				.catch(() => {
					if (token !== openTokenRef.current) {
						return;
					}
					setLifecycle("load_error");
				});
		},
		[buildUrl, resetEditorState],
	);

	const requestClose = useCallback(
		(force = false): boolean => {
			if (isDirty && !force) {
				return false;
			}
			// A close supersedes any in-flight open fetch.
			openTokenRef.current += 1;
			setLifecycle("closed");
			resetEditorState();
			return true;
		},
		[isDirty, resetEditorState],
	);

	const setDirty = useCallback((dirty: boolean): void => {
		setIsDirty(dirty);
	}, []);

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
			const lockVersion = prefill?.validation.lock_version;
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
					setIsDirty(false);
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
		[buildSaveUrl, prefill],
	);

	// Return focus to the invoking control once the drawer has fully closed (spec
	// "Editor Contracts": "Return focus to the opening control after close").
	useEffect(() => {
		if (lifecycle !== "closed") {
			return;
		}
		if (typeof document === "undefined") {
			return;
		}
		const target =
			(invokerId ? document.getElementById(invokerId) : null) ??
			restoreFocusRef.current;
		target?.focus?.();
	}, [lifecycle, invokerId]);

	return {
		isOpen: lifecycle !== "closed",
		lifecycle,
		prefill,
		isDirty,
		saveState,
		isSaving: saveState === "saving",
		fieldErrors,
		summaryError,
		versionToken: prefill?.validation.lock_version ?? null,
		invokerId,
		open,
		save,
		requestClose,
		setDirty,
		setSaveState,
		setErrors,
		clearErrors,
	};
}
