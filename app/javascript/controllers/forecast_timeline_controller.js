import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="forecast-timeline"
//
// Swaps the timeline cash lane between its daily (0-90) and monthly (4-36)
// resolutions entirely client-side. Both resolutions are rendered server-side;
// the controller shows the one matching the selected resolution and reflects the
// active state via aria-pressed so the toggle is accessible and keyboard
// operable.
//
// Per Sure conventions, the chosen resolution is persisted as a `resolution`
// query param (state in the URL, not localStorage) without a request, so a
// reload / shared link reopens the same view.
export default class extends Controller {
  static targets = ["button", "pane"];
  static values = { resolution: { type: String, default: "daily" } };

  connect() {
    this.show(this.resolutionValue);
  }

  select(event) {
    const resolution = event.currentTarget.dataset.resolution;
    if (!resolution) return;
    this.show(resolution);
  }

  show(resolution) {
    this.resolutionValue = resolution;

    this.paneTargets.forEach((pane) => {
      pane.classList.toggle("hidden", pane.dataset.resolution !== resolution);
    });

    this.buttonTargets.forEach((button) => {
      button.setAttribute(
        "aria-pressed",
        button.dataset.resolution === resolution ? "true" : "false",
      );
    });

    this.syncUrl(resolution);
  }

  syncUrl(resolution) {
    const url = new URL(window.location.href);
    url.searchParams.set("resolution", resolution);
    window.history.replaceState(window.history.state, "", url.toString());
  }
}
