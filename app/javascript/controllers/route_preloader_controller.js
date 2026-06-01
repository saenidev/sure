import { Controller } from "@hotwired/stimulus";

const PREFETCH_INTERVAL_MS = 45_000;
const DELAY_BETWEEN_FETCHES_MS = 125;

export default class extends Controller {
  static values = {
    paths: Array,
  };

  connect() {
    this.abortController = new AbortController();
    this.schedulePreload();
  }

  disconnect() {
    this.abortController?.abort();

    if (this.idleCallback) {
      cancelIdleCallback(this.idleCallback);
    }

    if (this.timeout) {
      clearTimeout(this.timeout);
    }
  }

  schedulePreload() {
    if (!this.shouldPreload()) return;

    const preload = () => this.preloadPaths();

    if ("requestIdleCallback" in window) {
      this.idleCallback = requestIdleCallback(preload, { timeout: 1_500 });
    } else {
      this.timeout = setTimeout(preload, 750);
    }
  }

  shouldPreload() {
    const connection = navigator.connection;

    if (connection?.saveData) return false;
    if (["slow-2g", "2g"].includes(connection?.effectiveType)) return false;
    if (document.visibilityState !== "visible") return false;

    return true;
  }

  async preloadPaths() {
    for (const path of this.preloadablePaths()) {
      if (this.abortController.signal.aborted) return;

      this.markPreloaded(path);

      try {
        const response = await fetch(path, {
          credentials: "same-origin",
          signal: this.abortController.signal,
          priority: "low",
          headers: {
            Accept: "text/html",
            "X-Sure-Route-Preload": "1",
            "X-Sec-Purpose": "prefetch",
          },
        });

        if (!response.ok) {
          this.unmarkPreloaded(path);
        }
      } catch (error) {
        if (error.name !== "AbortError") {
          this.unmarkPreloaded(path);
        }
      }

      await this.delay(DELAY_BETWEEN_FETCHES_MS);
    }
  }

  preloadablePaths() {
    const currentPath = window.location.pathname;

    return [...new Set(this.pathsValue || [])].filter((path) => {
      if (!path || path === currentPath) return false;
      if (!path.startsWith("/")) return false;

      return !this.recentlyPreloaded(path);
    });
  }

  recentlyPreloaded(path) {
    const timestamp = Number(sessionStorage.getItem(this.storageKey(path)) || 0);

    return Date.now() - timestamp < PREFETCH_INTERVAL_MS;
  }

  markPreloaded(path) {
    sessionStorage.setItem(this.storageKey(path), Date.now().toString());
  }

  unmarkPreloaded(path) {
    sessionStorage.removeItem(this.storageKey(path));
  }

  storageKey(path) {
    return `sure:route-preload:${path}`;
  }

  delay(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
