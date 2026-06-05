import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// THROWAWAY Hotwire viability spike. Proves the two interactions the audit
// claims need Inertia/Vite are achievable in plain Hotwire:
//   1. Local chart scrub — pointer movement updates marker, metric strip, and
//      explanation with ZERO network requests.
//   2. Scoped save — a Turbo Stream patches only the affected regions; the
//      workspace shell is never replaced (Full-page-renders stays at 1).
//
// Delete with the rest of forecast_hotwire_spike. In the real Forecast V2 this
// single controller would be split (chart vs. period state vs. freshness).
export default class extends Controller {
  static targets = [
    "chart", "data", "metric", "explanation", "selectedLabel",
    "scrubLatency", "scrubNetwork", "saveLatency", "loadCount", "periodIndex",
  ];
  static values = { selectedIndex: Number };

  connect() {
    this.#wrapFetch();
    this.periods = [];
    this.selectedIndex = this.selectedIndexValue || 0;

    // Full-page-render counter: survives Turbo Stream updates (no reconnect),
    // only bumps on a real full navigation/reload.
    const loads = (Number(sessionStorage.getItem("fcSpikeLoads")) || 0) + 1;
    sessionStorage.setItem("fcSpikeLoads", loads);
    if (this.hasLoadCountTarget) this.loadCountTarget.textContent = loads;

    // Save round-trip timing + recomputing pill.
    this._onSubmitStart = () => {
      this._submitAt = performance.now();
      this.#setFreshness("recomputing");
    };
    this.element.addEventListener("turbo:submit-start", this._onSubmitStart);

    this._onResize = () => this.#redraw();
    window.addEventListener("resize", this._onResize);

    this._onKey = (e) => this.#onKey(e);
    if (this.hasChartTarget) this.chartTarget.addEventListener("keydown", this._onKey);
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-start", this._onSubmitStart);
    window.removeEventListener("resize", this._onResize);
    if (this.hasChartTarget) this.chartTarget.removeEventListener("keydown", this._onKey);
  }

  // Fires on first connect AND every time the server swaps the data island on
  // save — so a save redraws the chart at the current selected period.
  dataTargetConnected(el) {
    try {
      this.periods = JSON.parse(el.textContent);
    } catch (_) {
      this.periods = [];
    }
    this.#redraw();
    if (this._submitAt != null) {
      const ms = performance.now() - this._submitAt;
      if (this.hasSaveLatencyTarget) this.saveLatencyTarget.textContent = ms.toFixed(0);
      this._submitAt = null;
    }
  }

  // ---- drawing -------------------------------------------------------------

  #redraw() {
    if (!this.hasChartTarget || this.periods.length === 0) return;
    const el = this.chartTarget;
    el.replaceChildren();
    const w = el.clientWidth || 600;
    const h = el.clientHeight || 280;
    const m = { t: 12, r: 14, b: 22, l: 56 };
    const data = this.periods;

    const x = d3.scaleLinear().domain([0, data.length - 1]).range([m.l, w - m.r]);
    const ys = data.map((d) => d.metrics.net_worth);
    const y = d3.scaleLinear().domain([Math.min(...ys), Math.max(...ys)]).nice().range([h - m.b, m.t]);

    const svg = d3.select(el).append("svg").attr("width", w).attr("height", h);

    // light y gridlines + labels
    svg.append("g")
      .attr("transform", `translate(${m.l},0)`)
      .attr("class", "text-secondary")
      .call(d3.axisLeft(y).ticks(4).tickSize(-(w - m.l - m.r))
        .tickFormat((d) => d3.format("$.2s")(d)))
      .call((g) => g.select(".domain").remove())
      .call((g) => g.selectAll(".tick line").attr("stroke", "currentColor").attr("stroke-opacity", 0.15))
      .call((g) => g.selectAll(".tick text").attr("fill", "currentColor"));

    svg.append("path")
      .datum(data)
      .attr("fill", "none")
      .attr("stroke", "currentColor")
      .attr("stroke-width", 2)
      .attr("d", d3.line().x((d, i) => x(i)).y((d) => y(d.metrics.net_worth)));

    this._svg = svg;
    this._x = x;
    this._y = y;

    svg.append("rect")
      .attr("x", m.l).attr("y", m.t)
      .attr("width", w - m.l - m.r).attr("height", h - m.t - m.b)
      .attr("fill", "transparent").style("cursor", "crosshair")
      .on("pointerenter", (ev) => this.#onEnter(ev))
      .on("pointermove", (ev) => this.#onMove(ev));

    this._marker = svg.append("line")
      .attr("class", "text-secondary")
      .attr("stroke", "currentColor").attr("stroke-dasharray", "3,3")
      .attr("y1", m.t).attr("y2", h - m.b);
    this._dot = svg.append("circle").attr("r", 4).attr("fill", "currentColor");

    this.#placeMarker();
    this.#renderSelection();
  }

  #placeMarker() {
    if (!this._marker) return;
    const px = this._x(this.selectedIndex);
    const py = this._y(this.periods[this.selectedIndex].metrics.net_worth);
    this._marker.attr("x1", px).attr("x2", px);
    this._dot.attr("cx", px).attr("cy", py);
  }

  // ---- interaction (LOCAL — no network) ------------------------------------

  #onEnter() {
    this._fetchAtGestureStart = window.__fcFetch || 0;
  }

  #onMove(ev) {
    const [mx] = d3.pointer(ev, this._svg.node());
    const i = Math.round(this._x.invert(mx));
    this.#select(i);
  }

  #onKey(e) {
    if (e.key === "ArrowRight") { this.#select(this.selectedIndex + 1); e.preventDefault(); }
    else if (e.key === "ArrowLeft") { this.#select(this.selectedIndex - 1); e.preventDefault(); }
  }

  #select(i) {
    const idx = Math.max(0, Math.min(this.periods.length - 1, i));
    if (idx === this.selectedIndex && this._marker) return;
    const t0 = performance.now();

    this.selectedIndex = idx;
    this.#placeMarker();
    this.#renderSelection();
    this.periodIndexTargets.forEach((el) => {
      el.value = idx;
    });

    const dt = performance.now() - t0;
    if (this.hasScrubLatencyTarget) this.scrubLatencyTarget.textContent = dt.toFixed(1);
    if (this.hasScrubNetworkTarget) {
      this.scrubNetworkTarget.textContent = (window.__fcFetch || 0) - (this._fetchAtGestureStart || 0);
    }
  }

  #renderSelection() {
    const p = this.periods[this.selectedIndex];
    if (!p) return;
    if (this.hasSelectedLabelTarget) this.selectedLabelTarget.textContent = p.label;

    this.metricTargets.forEach((t) => {
      const k = t.dataset.metricKey;
      t.textContent = this.#fmt(k, p.metrics[k]);
    });

    if (this.hasExplanationTarget) {
      // Build nodes explicitly (no innerHTML) — values are our own numbers/labels.
      const items = p.explanation.map((l) => {
        const li = document.createElement("li");
        li.className = "flex items-center justify-between text-sm";

        const label = document.createElement("span");
        label.className = "text-secondary";
        label.textContent = l.label;

        const amount = document.createElement("span");
        amount.className = `tabular-nums ${l.amount < 0 ? "text-red-500" : "text-green-600"}`;
        amount.textContent = this.#fmt("amount", l.amount);

        li.append(label, amount);
        return li;
      });
      this.explanationTarget.replaceChildren(...items);
    }
  }

  // ---- helpers -------------------------------------------------------------

  #fmt(key, val) {
    if (key === "runway_days") return `${val} d`;
    return val.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
  }

  #setFreshness(state) {
    const el = document.getElementById("forecast-spike-freshness");
    if (!el) return;
    el.textContent = state === "recomputing" ? "Recomputing…" : "Fresh";
  }

  // Count every fetch so the HUD can prove scrub issues none and a save issues one.
  #wrapFetch() {
    if (window.__fcFetchWrapped) return;
    const orig = window.fetch;
    window.__fcFetch = 0;
    window.fetch = (...args) => {
      window.__fcFetch += 1;
      return orig(...args);
    };
    window.__fcFetchWrapped = true;
  }
}
