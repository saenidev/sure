// Forecast V2 AssumptionEditor drawer (slice C7).
//
// The typed editor-drawer SHELL the spec's "Editor Contracts" require: it opens
// from an assumption card, preserves plan / scenario stack / lens / selected
// period (owned by the shared workspace store the drawer renders OVER), shows
// field-level errors plus a top-level summary, warns on a dirty close, offers
// save + cancel, and returns focus to the invoking control after close (the focus
// return is owned by `useAssumptionEditor`).
//
// Composition (spec "Editor Contracts"): the shell is type-agnostic; it delegates
// the assumption-specific schema + field rendering to `SalaryForm`, which selects
// its layout from the prefill's `form_key`. Extracting the form keeps this module
// focused on drawer chrome (slice F12).
//
// Dirty-close warning (spec "Editor Contracts": "warn on a dirty close"): every
// close path goes through `attemptClose`, which calls `editor.requestClose()`.
// When the form is dirty that returns `false`, so the drawer surfaces a visible
// confirmation (the existing `dirty_warning` / `discard` / `keep_editing` copy):
// Discard forces the close, Keep editing dismisses the warning.
//
// Lifecycle / dirty / save / errors / version token all come from
// `useAssumptionEditor`; this component is presentational. Tokens only — no raw
// palette; copy resolves through the client i18n table (`ft`). Save drives the
// typed PATCH (`useAssumptionEditor.save`, slice C8); on a committed save it hands
// the changed-region patch to `onSaved` so the parent patches scoped regions
// without a full reload (the patch fold + recompute stay in the parent).

import { type JSX, useEffect, useRef, useState } from "react";
import type { UseAssumptionEditorResult } from "../hooks/useAssumptionEditor";
import { ft } from "../i18n";
import type { SavedAssumptionPatch } from "../types/readModels";
import SalaryForm from "./SalaryForm";

const FORM_ID = "forecast-assumption-editor-form";

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
   * (slice C8). The parent folds it into the workspace store + scoped regions
   * WITHOUT a full reload, then the drawer closes. The save itself is owned by
   * `useAssumptionEditor.save`; this component only drives it — editor lifecycle
   * and recompute orchestration stay separate (spec "Frontend module rules").
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

  // Whether the dirty-close confirmation is showing. A close path sets this when
  // `editor.requestClose()` is blocked by unsaved edits; the confirmation then
  // forces the close (discard) or dismisses (keep editing). It never persists
  // across opens — the open lifecycle clears it below.
  const [confirmingClose, setConfirmingClose] = useState(false);

  // Focus the panel when it opens (focus trap entry; the panel is the first
  // focus stop, and focus return on close is owned by the hook).
  useEffect(() => {
    if (editor.lifecycle === "ready") {
      panelRef.current?.focus();
    }
  }, [editor.lifecycle]);

  // Drop any pending dirty-close confirmation when the drawer fully closes, so a
  // later open never starts mid-warning.
  useEffect(() => {
    if (!editor.isOpen) {
      setConfirmingClose(false);
    }
  }, [editor.isOpen]);

  if (!editor.isOpen) {
    return null;
  }

  // The single close path for every affordance (Escape, backdrop, ×, Cancel).
  // `requestClose()` closes immediately when the form is clean; when it's dirty it
  // returns `false` and we surface the visible discard/keep-editing confirmation
  // (spec "Editor Contracts": warn on a dirty close).
  const attemptClose = (): void => {
    if (!editor.requestClose()) {
      setConfirmingClose(true);
    }
  };

  // Trap focus inside the panel and close on Escape (Escape routes through
  // `attemptClose`, so a dirty Escape surfaces the warning rather than discarding).
  const handleKeyDown = (event: React.KeyboardEvent<HTMLDivElement>): void => {
    if (event.key === "Escape") {
      event.stopPropagation();
      attemptClose();
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

  // Capture the prefill once so TS narrowing holds for the form and the scenario
  // label is resolved once.
  const prefill = editor.prefill;
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
    // biome-ignore lint/a11y/useKeyWithClickEvents: backdrop click-to-close is a mouse affordance; keyboard users close via Escape (handled on the panel).
    <div
      data-testid="forecast-assumption-editor-overlay"
      className="fixed inset-0 z-50 flex justify-end bg-overlay"
      onClick={attemptClose}
    >
      <div
        ref={panelRef}
        data-testid="forecast-assumption-editor"
        // biome-ignore lint/a11y/useSemanticElements: this is a custom slide-in panel, not a native <dialog>; modal semantics are provided via role/aria-modal and focus handling.
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
            onClick={attemptClose}
            className="rounded-lg border border-primary px-2 py-1 text-sm text-secondary hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400"
          >
            ×
          </button>
        </header>

        <div className="flex-1 overflow-y-auto p-4">
          {editor.lifecycle === "loading" ? (
            <p className="text-sm text-subdued">
              {ft("forecasts.editor.loading")}
            </p>
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
            <SalaryForm
              prefill={prefill}
              fieldErrors={editor.fieldErrors}
              summaryError={editor.summaryError}
              formId={FORM_ID}
              onSubmit={handleSave}
              onDirty={() => editor.setDirty(true)}
            />
          ) : null}
        </div>

        {/* Dirty-close confirmation (spec "Editor Contracts": warn on a dirty
				    close). Shown when a close path was blocked by unsaved edits. Discard
				    forces the close; Keep editing dismisses and returns to the form. */}
        {confirmingClose ? (
          <div
            data-testid="forecast-assumption-editor-dirty-warning"
            role="alertdialog"
            aria-label={ft("forecasts.editor.dirty_warning")}
            className="border-t border-primary bg-surface p-4"
          >
            <p className="text-sm text-primary">
              {ft("forecasts.editor.dirty_warning")}
            </p>
            <div className="mt-3 flex items-center justify-end gap-2">
              <button
                type="button"
                data-testid="forecast-assumption-editor-keep-editing"
                onClick={() => setConfirmingClose(false)}
                className="rounded-lg border border-primary px-3 py-1.5 text-sm text-secondary hover:bg-container focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400"
              >
                {ft("forecasts.editor.keep_editing")}
              </button>
              <button
                type="button"
                data-testid="forecast-assumption-editor-discard"
                onClick={() => editor.requestClose(true)}
                className="rounded-lg border border-warning px-3 py-1.5 text-sm font-medium text-warning hover:bg-container focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400"
              >
                {ft("forecasts.editor.discard")}
              </button>
            </div>
          </div>
        ) : null}

        <footer className="flex items-center justify-end gap-2 border-t border-primary p-4">
          <button
            type="button"
            data-testid="forecast-assumption-editor-cancel"
            disabled={editor.isSaving}
            onClick={attemptClose}
            className="rounded-lg border border-primary px-3 py-1.5 text-sm text-secondary hover:bg-surface focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-gray-400 disabled:opacity-50"
          >
            {ft("forecasts.editor.cancel")}
          </button>
          <button
            type="submit"
            form={FORM_ID}
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
