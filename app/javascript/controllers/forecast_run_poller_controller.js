import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="forecast-run-poller"
//
// Polls the family-scoped forecast run-group status endpoint while a generation
// is in flight. When the group reaches a terminal state (completed/failed) it
// reloads the workspace so the user sees the resulting Overview or the failure
// alert without a manual refresh. Polling stops on disconnect to avoid leaks.
export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 3000 },
  };

  connect() {
    this.startPolling();
  }

  disconnect() {
    this.stopPolling();
  }

  startPolling() {
    if (!this.hasUrlValue || this.urlValue === "") return;

    this.timer = setInterval(() => {
      this.checkStatus();
    }, this.intervalValue);
  }

  stopPolling() {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  async checkStatus() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
      });

      if (!response.ok) {
        // A 404 means the group is gone / not ours; stop quietly.
        this.stopPolling();
        return;
      }

      const data = await response.json();
      if (data.done) {
        this.stopPolling();
        this.reload();
      }
    } catch (error) {
      // Transient network error: keep polling on the next tick.
    }
  }

  reload() {
    if (window.Turbo) {
      window.Turbo.visit(window.location.href, { action: "replace" });
    } else {
      window.location.reload();
    }
  }
}
