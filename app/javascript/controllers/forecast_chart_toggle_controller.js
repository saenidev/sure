import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="forecast-chart-toggle"
//
// Switches the cash-runway card between its line variants (cash / liquid)
// entirely client-side. Each button and panel carries a `data-line` token; the
// controller shows the matching panel and reflects the active state via
// aria-pressed so the toggle is accessible and keyboard-operable. No request is
// made — both series are already rendered server-side.
export default class extends Controller {
  static targets = ["button", "panel"];

  select(event) {
    const line = event.currentTarget.dataset.line;
    this.show(line);
  }

  show(line) {
    this.panelTargets.forEach((panel) => {
      panel.classList.toggle("hidden", panel.dataset.line !== line);
    });

    this.buttonTargets.forEach((button) => {
      button.setAttribute(
        "aria-pressed",
        button.dataset.line === line ? "true" : "false",
      );
    });
  }
}
