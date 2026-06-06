// Forecast V2 AssumptionEditor drawer (slice C7).
//
// The typed editor-drawer SHELL the spec's "Editor Contracts" require: it opens
// from an assumption card, preserves plan / scenario stack / lens / selected
// period (all owned by the shared workspace store the drawer renders OVER — this
// component owns none of it), shows field-level errors plus a top-level summary,
// warns on a dirty close, offers save + cancel, and returns focus to the invoking
// control after close (the focus return is owned by `useAssumptionEditor`).
//
// Composition (spec "Editor Contracts": editors compose an assumption-specific
// form schema): the shell is type-agnostic; it composes the salary-specific form
// schema (`SALARY_SCHEMA`) selected by the prefill's `form_key`. The salary form
// is the only interactive editor in the MVP, so an unknown `form_key` renders a
// neutral "unsupported" body rather than guessing a layout.
//
// Lifecycle / dirty / save / errors / version token all come from
// `useAssumptionEditor`; this component is presentational. Tokens only — no raw
// palette; copy resolves through the client i18n table (`ft`). Money inputs carry
// `privacy-sensitive` so the app-wide privacy toggle blurs them with no
// forecast-specific JS. Save collects the form values and drives the typed PATCH
// save (`useAssumptionEditor.save`, slice C8); on a committed save it hands the
// changed-region patch to `onSaved` so the parent patches scoped regions without a
// full reload (the patch fold + recompute orchestration stay in the parent).

import { type JSX, useEffect, useRef } from "react";
import type { UseAssumptionEditorResult } from "../hooks/useAssumptionEditor";
import { ft } from "../i18n";
import type {
	EditorPrefillReadModel,
	SavedAssumptionPatch,
} from "../types/readModels";

// One field in a composed form schema. `options` makes it a select; otherwise the
// `type` drives an <input>. `param` reads/writes the value from the prefill's
// `params` bag; otherwise it reads a top-level primary value.
interface EditorField {
	readonly name: string;
	readonly labelKey: string;
	readonly type: "text" | "number" | "date" | "select";
	readonly param?: boolean;
	readonly options?: ReadonlyArray<{ readonly value: string; readonly labelKey: string }>;
}

// The salary form schema (spec "Initial Assumption Type Catalog" -> salary: name,
// amount, currency, earner, gross/net, frequency, growth, timing). The shell keeps
// the primary financial fields visible — no advanced disclosure hides amount,
// timing, or treatment (spec "Editor Contracts").
const SALARY_SCHEMA: ReadonlyArray<EditorField> = [
	{ name: "name", labelKey: "forecasts.editor.salary.name_label", type: "text" },
	{ name: "amount", labelKey: "forecasts.editor.salary.amount_label", type: "number" },
	{ name: "currency", labelKey: "forecasts.editor.salary.currency_label", type: "text" },
	{
		name: "person_key",
		labelKey: "forecasts.editor.salary.person_key_label",
		type: "text",
		param: true,
	},
	{
		name: "gross_or_net",
		labelKey: "forecasts.editor.salary.gross_or_net_label",
		type: "select",
		param: true,
		options: [
			{ value: "gross", labelKey: "forecasts.editor.salary.gross_or_net_gross" },
			{ value: "net", labelKey: "forecasts.editor.salary.gross_or_net_net" },
		],
	},
	{
		name: "frequency",
		labelKey: "forecasts.editor.salary.frequency_label",
		type: "select",
		param: true,
		options: [
			{ value: "annual", labelKey: "forecasts.editor.salary.frequency_annual" },
			{ value: "monthly", labelKey: "forecasts.editor.salary.frequency_monthly" },
			{ value: "biweekly", labelKey: "forecasts.editor.salary.frequency_biweekly" },
			{ value: "weekly", labelKey: "forecasts.editor.salary.frequency_weekly" },
		],
	},
	{
		name: "growth_policy",
		labelKey: "forecasts.editor.salary.growth_policy_label",
		type: "select",
		param: true,
		options: [
			{ value: "flat", labelKey: "forecasts.editor.salary.growth_policy_flat" },
			{ value: "fixed_rate", labelKey: "forecasts.editor.salary.growth_policy_fixed_rate" },
		],
	},
	{
		name: "growth_rate",
		labelKey: "forecasts.editor.salary.growth_rate_label",
		type: "number",
		param: true,
	},
	{ name: "starts_on", labelKey: "forecasts.editor.salary.starts_on_label", type: "date" },
	{ name: "ends_on", labelKey: "forecasts.editor.salary.ends_on_label", type: "date" },
];

const FORM_SCHEMAS: Readonly<Record<string, ReadonlyArray<EditorField>>> = {
	salary: SALARY_SCHEMA,
};

// The top-level primary values a field may read by name (everything outside the
// form-specific `params` bag). Narrowed so reads are type-safe without an unsafe
// index-signature cast on `EditorPrimaryValues`.
const PRIMARY_VALUE_READERS: Readonly<
	Record<string, (values: EditorPrefillReadModel["primary_values"]) => string | null>
> = {
	name: (values) => values.name,
	amount: (values) => values.amount,
	currency: (values) => values.currency,
	starts_on: (values) => values.starts_on,
	ends_on: (values) => values.ends_on,
};

// Read a field's current value from the typed prefill (top-level primary value or
// the `params` bag), coerced to a string the input can render.
function fieldValue(prefill: EditorPrefillReadModel, field: EditorField): string {
	const raw = field.param
		? prefill.primary_values.params[field.name]
		: PRIMARY_VALUE_READERS[field.name]?.(prefill.primary_values);
	if (raw === null || raw === undefined) {
		return "";
	}
	return String(raw);
}

// Localize a stable field error code (`"blank"`, `"not_positive"`, …).
function errorMessage(code: string): string {
	return ft(`forecasts.editor.errors.${code}`);
}

export interface AssumptionEditorProps {
	/** The drawer lifecycle handle from `useAssumptionEditor`. */
	readonly editor: UseAssumptionEditorResult;
	/**
	 * The plan version the workspace currently observes, echoed back on save so the
	 * server can reject a stale edit (spec "Live Recompute Model", "Conflict
	 * Handling"). Owned by the shared workspace store, passed in here.
	 */
	readonly planVersion: number;
	/**
	 * Notified AFTER a save commits (HTTP 200) with the typed changed-region patch
	 * (slice C8). The parent folds the patch into the workspace store + scoped
	 * regions (saved card, inspector, freshness) WITHOUT a full reload, then closes
	 * the drawer. The save itself (PATCH + typed errors/conflicts) is owned by
	 * `useAssumptionEditor.save`; this component only collects the form values and
	 * drives it (spec "Frontend module responsibility rules": editor lifecycle and
	 * recompute orchestration stay separate — the parent owns the patch fold).
	 */
	readonly onSaved?: (patch: SavedAssumptionPatch) => void;
}

export default function AssumptionEditor({
	editor,
	planVersion,
	onSaved,
}: AssumptionEditorProps): JSX.Element | null {
	const titleId = "forecast-assumption-editor-title";
	const panelRef = useRef<HTMLDivElement>(null);

	// Focus the panel when it opens (focus trap entry; the panel is the first
	// focus stop, and focus return on close is owned by the hook).
	useEffect(() => {
		if (editor.lifecycle === "ready") {
			panelRef.current?.focus();
		}
	}, [editor.lifecycle]);

	if (!editor.isOpen) {
		return null;
	}

	// Trap focus inside the panel and close on Escape (respecting the dirty-state
	// warning: a dirty Escape requests close, which the hook blocks so the parent
	// can surface the warning).
	const handleKeyDown = (event: React.KeyboardEvent<HTMLDivElement>): void => {
		if (event.key === "Escape") {
			event.stopPropagation();
			editor.requestClose();
			return;
		}
		if (event.key !== "Tab") {
			return;
		}
		const focusables = panelRef.current?.querySelectorAll<HTMLElement>(
			'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
		);
		if (!focusables || focusables.length === 0) {
			return;
		}
		const first = focusables[0];
		const last = focusables[focusables.length - 1];
		if (event.shiftKey && document.activeElement === first) {
			event.preventDefault();
			last.focus();
		} else if (!event.shiftKey && document.activeElement === last) {
			event.preventDefault();
			first.focus();
		}
	};

	// Capture the prefill once so TS narrowing holds inside the form's field map
	// (no per-field non-null cast) and the form-specific schema is resolved once.
	const prefill = editor.prefill;
	const schema = prefill ? FORM_SCHEMAS[prefill.form_key] : undefined;
	const scenarioLabel = prefill?.scenario_layer_id
		? ft("forecasts.editor.scenario_layer", {
				layer: prefill.scenario_layer_id,
			})
		: ft("forecasts.editor.scenario_baseline");

	// Collect the form values and drive the typed PATCH save (slice C8). On a
	// committed save (status "saved") notify the parent with the changed-region
	// patch so it patches scoped regions, then close the drawer. Invalid / conflict
	// outcomes keep the drawer open — `useAssumptionEditor.save` already set the
	// typed field/summary errors the form renders.
	const handleSave = (event: React.FormEvent<HTMLFormElement>): void => {
		event.preventDefault();
		if (!prefill) {
			return;
		}

		const formData = new FormData(event.currentTarget);
		const values: Record<string, string> = {};
		for (const [name, value] of formData.entries()) {
			if (typeof value === "string") {
				values[name] = value;
			}
		}

		void editor
			.save({
				assumptionId: prefill.assumption_id,
				kind: prefill.form_key,
				values,
				planVersion,
			})
			.then((outcome) => {
				if (outcome.status === "saved") {
					onSaved?.(outcome.patch);
					editor.requestClose(true);
				}
			});
	};

	return (
		// biome-ignore lint/a11y/useKeyWithClickEvents: backdrop click-to-close is a
		// mouse affordance; keyboard users close via Escape (handled on the panel).
		<div
			data-testid="forecast-assumption-editor-overlay"
			className="fixed inset-0 z-50 flex justify-end bg-black/30"
			onClick={() => editor.requestClose()}
		>
			<div
				ref={panelRef}
				data-testid="forecast-assumption-editor"
				role="dialog"
				aria-modal="true"
				aria-labelledby={titleId}
				tabIndex={-1}
				onClick={(event) => event.stopPropagation()}
				onKeyDown={handleKeyDown}
				className="flex h-full w-full max-w-md flex-col bg-container shadow-xl focus-visible:outline-none"
			>
				<header className="flex items-start justify-between gap-3 border-b border-primary p-4">
					<div className="flex flex-col gap-0.5">
						<h2 id={titleId} className="text-base font-semibold text-primary">
							{ft("forecasts.editor.title")}
						</h2>
						<p
							data-testid="forecast-assumption-editor-scenario"
							className="text-xs text-subdued"
						>
							{scenarioLabel}
						</p>
					</div>
					<button
						type="button"
						data-testid="forecast-assumption-editor-close"
						aria-label={ft("forecasts.editor.close")}
						onClick={() => editor.requestClose()}
						className="rounded-lg border border-primary px-2 py-1 text-sm text-secondary hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400"
					>
						×
					</button>
				</header>

				<div className="flex-1 overflow-y-auto p-4">
					{editor.lifecycle === "loading" ? (
						<p className="text-sm text-subdued">{ft("forecasts.editor.loading")}</p>
					) : null}

					{editor.lifecycle === "load_error" ? (
						<p
							data-testid="forecast-assumption-editor-load-error"
							className="rounded-lg border border-warning bg-surface p-3 text-sm text-warning"
						>
							{ft("forecasts.editor.load_error")}
						</p>
					) : null}

					{editor.lifecycle === "ready" && prefill ? (
						<form
							id="forecast-assumption-editor-form"
							data-testid="forecast-assumption-editor-form"
							onSubmit={handleSave}
							onChange={() => editor.setDirty(true)}
							className="flex flex-col gap-4"
						>
							{editor.summaryError ? (
								<p
									data-testid="forecast-assumption-editor-summary-error"
									role="alert"
									className="rounded-lg border border-warning bg-surface p-3 text-sm text-warning"
								>
									{ft("forecasts.editor.summary_error")}
								</p>
							) : null}

							{schema === undefined ? (
								<p className="text-sm text-subdued">{prefill.form_key}</p>
							) : (
								schema.map((field) => {
									const fieldId = `forecast-editor-field-${field.name}`;
									const errorCode = editor.fieldErrors[field.name];
									return (
										<div key={field.name} className="flex flex-col gap-1">
											<label
												htmlFor={fieldId}
												className="text-xs font-medium text-secondary"
											>
												{ft(field.labelKey)}
											</label>
											{field.type === "select" ? (
												<select
													id={fieldId}
													name={field.name}
													data-testid={fieldId}
													defaultValue={fieldValue(prefill, field)}
													className="rounded-lg border border-primary bg-container px-3 py-2 text-sm text-primary"
												>
													{field.options?.map((option) => (
														<option key={option.value} value={option.value}>
															{ft(option.labelKey)}
														</option>
													))}
												</select>
											) : (
												<input
													id={fieldId}
													name={field.name}
													type={field.type}
													data-testid={fieldId}
													defaultValue={fieldValue(prefill, field)}
													className={`rounded-lg border border-primary bg-container px-3 py-2 text-sm text-primary ${field.name === "amount" ? "privacy-sensitive" : ""}`}
												/>
											)}
											{errorCode ? (
												<p
													data-testid={`${fieldId}-error`}
													className="text-xs text-warning"
												>
													{errorMessage(errorCode)}
												</p>
											) : null}
										</div>
									);
								})
							)}
						</form>
					) : null}
				</div>

				<footer className="flex items-center justify-end gap-2 border-t border-primary p-4">
					<button
						type="button"
						data-testid="forecast-assumption-editor-cancel"
						disabled={editor.isSaving}
						onClick={() => editor.requestClose()}
						className="rounded-lg border border-primary px-3 py-1.5 text-sm text-secondary hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400 disabled:opacity-50"
					>
						{ft("forecasts.editor.cancel")}
					</button>
					<button
						type="submit"
						form="forecast-assumption-editor-form"
						data-testid="forecast-assumption-editor-save"
						disabled={editor.isSaving || editor.lifecycle !== "ready"}
						className="rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-inverse hover:opacity-90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400 disabled:opacity-50"
					>
						{editor.isSaving
							? ft("forecasts.editor.saving")
							: ft("forecasts.editor.save")}
					</button>
				</footer>
			</div>
		</div>
	);
}
