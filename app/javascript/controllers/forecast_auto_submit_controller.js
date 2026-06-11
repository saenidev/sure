import { Controller } from "@hotwired/stimulus";

// Settle-then-save for the assumption drawer (spec §4.6): the form submits
// ~600ms after the user stops typing, or on change for selects. One request at
// a time — a save in flight defers the next submit until it settles, so the
// drawer can never race itself. Full pipeline discipline (coalescing across
// cards, lock token threading, undo) lands with the preview engine in phase 4.
export default class extends Controller {
  static targets = ["status"];
  static values = {
    delay: { type: Number, default: 600 },
    saving: String,
    saved: String,
    retry: String,
  };

  connect() {
    this.inFlight = false;
    this.queued = false;
    this.element.addEventListener("turbo:submit-end", this.onSettled);
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.onSettled);
    clearTimeout(this.timer);
  }

  queue() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.submit(), this.delayValue);
  }

  submit() {
    if (this.inFlight) {
      this.queued = true;
      return;
    }
    this.inFlight = true;
    this.setStatus("saving");
    this.element.requestSubmit();
  }

  onSettled = (event) => {
    this.inFlight = false;
    this.setStatus(event.detail.success ? "saved" : "retry");
    if (this.queued) {
      this.queued = false;
      this.submit();
    }
  };

  // Labels arrive as Stimulus values rendered from i18n in the form partials
  // (data-forecast-auto-submit-saving-value etc.) — no hardcoded English here.
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
