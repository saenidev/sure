import { Controller } from "@hotwired/stimulus";
import { requestSave, settled } from "forecast/save_pipeline";

// Single-level undo toast for assumption saves (spec §4.6). Listens for
// forecast:assumption-saved (dispatched by forecast-auto-submit with the
// PRE-edit field pairs, the form action URL, and the fresh lock version from
// the X-Forecast-Assumption-Lock response header). A newer save replaces the
// current entry. Undo PATCHes the pre-edit fields back through the SAME save
// pipeline (key "undo:<id>") so it can never race a drawer save; the
// response is a Turbo Stream and is rendered as-is — a 409 stale-lock body
// is still a restream, which is exactly the "server wins visibly" path.
//
// All labels arrive as Stimulus values rendered from i18n in show.html.erb —
// no hardcoded English. DOM is built with createElement/replaceChildren
// only, never innerHTML, so the assumption name can never execute.
export default class extends Controller {
  static values = {
    savedTemplate: String,
    undoLabel: String,
    dismissLabel: String,
  };

  connect() {
    this.entry = null;
    this.onSaved = (event) => this.show(event.detail);
    window.addEventListener("forecast:assumption-saved", this.onSaved);
  }

  disconnect() {
    window.removeEventListener("forecast:assumption-saved", this.onSaved);
    clearTimeout(this.hideTimer);
  }

  show(entry) {
    this.entry = entry;
    this.render();
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => this.dismiss(), 8000);
  }

  dismiss() {
    clearTimeout(this.hideTimer);
    this.entry = null;
    this.element.replaceChildren();
  }

  undo() {
    const entry = this.entry;
    if (!entry) return;
    this.dismiss();
    window.dispatchEvent(new CustomEvent("forecast:preview-clear"));
    requestSave(`undo:${entry.assumptionId}`, () => this.performUndo(entry));
  }

  // Rides the save pipeline: requestSave fired us, so settled() MUST run
  // when the request finishes (success or failure) — hence the .finally.
  performUndo(entry) {
    const body = new URLSearchParams(entry.fields);
    body.append("assumption[expected_lock_version]", entry.lockVersion);
    fetch(entry.url, {
      method: "PATCH",
      headers: {
        Accept: "text/vnd.turbo-stream.html",
        "X-CSRF-Token": this.csrfToken(),
      },
      body,
    })
      .then((response) => response.text())
      .then((text) => window.Turbo.renderStreamMessage(text))
      .catch((error) => console.error("Forecast undo failed", error))
      .finally(() => settled());
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || "";
  }

  render() {
    const toast = document.createElement("div");
    toast.className =
      "flex items-center gap-3 rounded-lg bg-container p-4 shadow-border-xs";
    toast.setAttribute("role", "status");
    toast.setAttribute("aria-live", "polite");

    const message = document.createElement("p");
    message.className = "text-sm font-medium text-primary";
    message.textContent = this.savedTemplateValue.replace(
      "%{name}",
      this.entry.name,
    );

    const undoButton = document.createElement("button");
    undoButton.type = "button";
    undoButton.className = "text-sm font-medium text-link";
    undoButton.textContent = this.undoLabelValue;
    undoButton.dataset.action = "forecast-undo-toast#undo";

    const dismissButton = document.createElement("button");
    dismissButton.type = "button";
    dismissButton.className = "text-sm text-subdued";
    dismissButton.textContent = "×";
    dismissButton.setAttribute("aria-label", this.dismissLabelValue);
    dismissButton.dataset.action = "forecast-undo-toast#dismiss";

    toast.append(message, undoButton, dismissButton);
    this.element.replaceChildren(toast);
  }
}
