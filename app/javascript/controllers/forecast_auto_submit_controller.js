import { Controller } from "@hotwired/stimulus";
import { normalizeFormValues } from "forecast/form_params";
import {
  WATCHDOG_MS,
  hasQueued,
  requestSave,
  settled,
} from "forecast/save_pipeline";

// Settle-then-save for the assumption drawer (spec §4.6), riding the shared
// save pipeline so edits across DIFFERENT cards coalesce too: at most one
// PATCH is in flight workspace-wide, and queued saves keep only the LATEST
// submit per assumption (key = assumption id).
//
// Live preview: every keystroke dispatches forecast:preview immediately (the
// JS preview engine is ~0ms) while the actual submit stays debounced 600ms.
// When a Turbo Stream replaces the island, the chart dispatches
// forecast:island-connected and any editor with dirty unsettled edits
// re-applies its preview — a stale stream never clobbers a newer edit.
export default class extends Controller {
  static targets = ["status"];
  static values = {
    assumptionId: String,
    delay: { type: Number, default: 600 },
    saving: String,
    saved: String,
    retry: String,
  };

  connect() {
    this.dirty = false;
    // True between this form's requestSubmit() firing and its
    // turbo:submit-end settling the pipeline — disconnect() uses it to
    // settle on the form's behalf when the drawer is detached mid-flight.
    this.awaitingSettle = false;
    // Undo unit = ONE coalesced save: the toast must restore the state the
    // user last saw applied. baseline is captured at connect and rolled
    // forward to the SUBMITTED payload after each success — capturing the
    // current DOM at settle time instead would leak keystrokes typed after
    // the submit into the baseline, so undo would "restore" a state the
    // server never had.
    this.baseline = this.captureFields();
    this.submittedFields = null;

    this.onSubmitStart = (event) => this.captureSubmission(event);
    this.onSubmitEnd = (event) => this.handleSettled(event);
    this.onIslandConnected = () => {
      if (this.dirty) this.dispatchPreview();
    };
    this.element.addEventListener("turbo:submit-start", this.onSubmitStart);
    this.element.addEventListener("turbo:submit-end", this.onSubmitEnd);
    window.addEventListener(
      "forecast:island-connected",
      this.onIslandConnected,
    );
  }

  disconnect() {
    this.element.removeEventListener(
      "turbo:submit-start",
      this.onSubmitStart,
    );
    this.element.removeEventListener("turbo:submit-end", this.onSubmitEnd);
    window.removeEventListener(
      "forecast:island-connected",
      this.onIslandConnected,
    );
    clearTimeout(this.timer);
    this.timer = null;
    if (this.awaitingSettle) {
      // Drawer closed with a save in flight. It still lands server-side and
      // re-streams the island with the values the preview already shows —
      // but its turbo:submit-end is dispatched on the DETACHED form and can
      // never reach our (just-removed) element-scoped listener, so settle
      // the pipeline here or it stays wedged until the watchdog (contract:
      // every fired submitter MUST call settled()).
      this.awaitingSettle = false;
      settled();
      // KEEP the preview across the round trip: clearing now flashes the
      // chart back to the pre-edit projection for ~0.5s until the restream
      // lands (live-test feedback: distracting double flash). The restream
      // replaces the island, so the fresh chart connects preview-free. If
      // the save FAILS, only the (now detached) drawer form is re-streamed
      // — the fallback below clears the stale preview; it is a no-op when
      // the island was already replaced.
      setTimeout(() => {
        window.dispatchEvent(new CustomEvent("forecast:preview-clear"));
      }, WATCHDOG_MS);
    } else {
      // No save will land for this edit (a pending debounce was dropped
      // above; a queued-but-unfired save self-drops via the isConnected
      // guard) — return the chart to the saved projection now.
      window.dispatchEvent(new CustomEvent("forecast:preview-clear"));
    }
  }

  queue() {
    this.dirty = true;
    this.dispatchPreview();
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      this.submit();
    }, this.delayValue);
  }

  submit() {
    requestSave(this.assumptionIdValue, () => {
      // A queued save can fire AFTER the drawer was detached (closed, or
      // replaced by another card's drawer). requestSubmit() on a
      // disconnected form is a silent no-op per the HTML form-submission
      // algorithm — no turbo:submit-* events would ever fire and the
      // pipeline would wedge until the watchdog. Settle immediately and
      // drop the edit instead (consistent with disconnect() clearing the
      // debounce timer for not-yet-fired edits).
      if (!this.element.isConnected) {
        settled();
        return;
      }
      this.awaitingSettle = true;
      this.setStatus("saving");
      this.element.requestSubmit();
    });
  }

  // --- pipeline plumbing ---

  captureSubmission(event) {
    this.submittedFields = this.assumptionEntries(
      event.detail.formSubmission.body,
    );
  }

  handleSettled(event) {
    this.awaitingSettle = false;
    settled();
    this.setStatus(event.detail.success ? "saved" : "retry");
    if (!event.detail.success) return;

    const lockVersion = event.detail.fetchResponse?.response?.headers?.get(
      "X-Forecast-Assumption-Lock",
    );
    // No lock header -> no undo offer: a compensating PATCH without a fresh
    // token could only 409. The status label still shows "Saved".
    if (lockVersion) {
      window.dispatchEvent(
        new CustomEvent("forecast:assumption-saved", {
          detail: {
            assumptionId: this.assumptionIdValue,
            name: this.savedName(),
            url: this.element.action,
            fields: this.baseline,
            lockVersion,
          },
        }),
      );
    }
    this.baseline = this.submittedFields || this.baseline;
    if (!this.timer && !hasQueued(this.assumptionIdValue)) {
      this.dirty = false;
    }
  }

  // --- preview ---

  dispatchPreview() {
    window.dispatchEvent(
      new CustomEvent("forecast:preview", {
        detail: {
          assumptionId: this.assumptionIdValue,
          params: normalizeFormValues(this.formValues()),
        },
      }),
    );
  }

  // --- form snapshots ---

  // assumption[...] entries minus the lock token, as [name, value] pairs —
  // the exact shape the undo toast PATCHes back.
  assumptionEntries(formData) {
    const fields = [];
    for (const [name, value] of formData.entries()) {
      if (
        name.startsWith("assumption[") &&
        name !== "assumption[expected_lock_version]"
      ) {
        fields.push([name, value]);
      }
    }
    return fields;
  }

  captureFields() {
    return this.assumptionEntries(new FormData(this.element));
  }

  formValues() {
    return Object.fromEntries(
      this.captureFields().map(([name, value]) => [
        name.slice("assumption[".length, -1),
        value,
      ]),
    );
  }

  savedName() {
    const entry = (this.submittedFields || []).find(
      ([name]) => name === "assumption[name]",
    );
    return entry ? entry[1] : "";
  }

  // Labels arrive as Stimulus values rendered from i18n in the form partials
  // (data-forecast-auto-submit-saving-value etc.) — no hardcoded English.
  setStatus(state) {
    if (!this.hasStatusTarget) return;
    const labels = {
      saving: this.savingValue,
      saved: this.savedValue,
      retry: this.retryValue,
    };
    this.statusTarget.textContent = labels[state] || "";
  }
}
