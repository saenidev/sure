import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  UNBOUNDED_RUNWAY_DAYS,
  previewPeriods,
} from "forecast/preview_engine";

// Renders the forecast projection from the #forecast-island JSON and keeps
// scrubbing/lens-switching/live-preview 100% client-side (spec §4/§11: zero
// network for scrub, lens switch, period inspect, and per-keystroke preview).
// The island element is replaced by Turbo Streams after a save; Stimulus
// disconnect/reconnect re-reads it, then dispatches
// forecast:island-connected so editors with dirty unsettled edits re-apply
// their preview (§4.6 — a stale stream must never clobber a newer edit).
//
// Lenses map island metric keys: nw, lc, pv, db are direct; "sv" (saving
// rate) is computed as income - spending per month. All user-facing strings
// come from the island's `labels` section (server-rendered i18n) — no
// hardcoded English in this file. All DOM is built with
// document.createElement/replaceChildren — never innerHTML — so
// island-derived strings can never execute.
export default class extends Controller {
  static targets = [
    "canvas",
    "scrubber",
    "axis",
    "metricColumn",
    "inspector",
    "lensTab",
  ];
  static values = { islandId: String, lens: { type: String, default: "nw" } };

  connect() {
    const el = document.getElementById(this.islandIdValue);
    if (!el) return;
    this.island = JSON.parse(el.textContent);
    this.labels = this.island.labels || { metrics: {}, inspector: {} };
    this.packet = this.island.packet || null;
    this.ordinalById = new Map(
      (this.island.assumptions || []).map((a, i) => [a.id, i]),
    );
    this.preview = null;
    this.periods = this.island.periods;
    this.dragging = false;
    this.formatter = new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: this.island.plan.currency,
      maximumFractionDigits: 0,
    });

    this.scrubberTarget.max = String(this.periods.length - 1);
    this.scrubberTarget.value = "0";
    this.renderAxis();
    this.renderChart();
    this.renderSelection(0);
    this.highlightLens();

    this.resizeObserver = new ResizeObserver(() => this.renderChart());
    this.resizeObserver.observe(this.canvasTarget);

    this.onPreview = (event) => this.applyPreview(event.detail);
    this.onPreviewClear = () => this.clearPreview();
    window.addEventListener("forecast:preview", this.onPreview);
    window.addEventListener("forecast:preview-clear", this.onPreviewClear);

    window.dispatchEvent(new CustomEvent("forecast:island-connected"));
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    window.removeEventListener("forecast:preview", this.onPreview);
    window.removeEventListener("forecast:preview-clear", this.onPreviewClear);
  }

  switchLens(event) {
    this.lensValue = event.currentTarget.dataset.lens;
    this.highlightLens();
    this.renderChart();
    this.renderSelection(this.selectedIndex());
  }

  scrub() {
    this.renderSelection(this.selectedIndex());
    this.positionScrubLine();
  }

  // --- live preview (forecast:preview / forecast:preview-clear) ---

  applyPreview(detail) {
    if (!this.packet || !detail) return;
    const card = (this.packet.assumptions || []).find(
      (a) => a.id === detail.assumptionId,
    );
    if (!card || !card.pv) return;
    try {
      this.preview = previewPeriods(
        this.packet,
        this.island.periods,
        detail.assumptionId,
        detail.params,
        this.ordinalById.get(detail.assumptionId),
      );
    } catch (error) {
      // Spec §11a: a preview/parity bug is a flicker, never a wrong plan —
      // fall back to the saved island projection.
      console.error(
        "Forecast preview failed, showing saved projection",
        error,
      );
      this.preview = null;
    }
    this.refreshSeries();
  }

  clearPreview() {
    if (!this.preview) return;
    this.preview = null;
    this.refreshSeries();
  }

  refreshSeries() {
    this.periods = this.preview || this.island.periods;
    this.renderChart();
    this.renderSelection(this.selectedIndex());
  }

  // --- pointer scrub & hover ---

  pointerDown(event) {
    if (!this.xScale) return;
    this.dragging = true;
    this.canvasTarget.setPointerCapture(event.pointerId);
    this.hideHover();
    this.scrubTo(this.indexAt(event));
  }

  pointerMove(event) {
    if (!this.xScale) return;
    if (this.dragging) {
      this.scrubTo(this.indexAt(event));
    } else {
      this.showHover(this.indexAt(event));
    }
  }

  pointerUp(event) {
    if (!this.dragging) return;
    this.dragging = false;
    if (this.canvasTarget.hasPointerCapture(event.pointerId)) {
      this.canvasTarget.releasePointerCapture(event.pointerId);
    }
  }

  pointerLeave() {
    // While dragging, pointer capture keeps the scrub alive past the edge —
    // only hide hover artifacts on a plain mouse-out.
    if (!this.dragging) this.hideHover();
  }

  indexAt(event) {
    const rect = this.canvasTarget.getBoundingClientRect();
    const raw = Math.round(this.xScale.invert(event.clientX - rect.left));
    return Math.max(0, Math.min(raw, this.periods.length - 1));
  }

  scrubTo(index) {
    this.scrubberTarget.value = String(index);
    this.renderSelection(index);
    this.positionScrubLine();
  }

  showHover(index) {
    const period = this.periods[index];
    if (!period || !this.hoverLine || !this.tooltip) return;
    const px = this.xScale(index);
    this.hoverLine
      .attr("x1", px)
      .attr("x2", px)
      .attr("visibility", "visible");
    this.tooltip.textContent = `${period.s.slice(0, 7)} · ${this.formatter.format(this.seriesValue(period))}`;
    this.tooltip.classList.remove("hidden");
    const left = Math.max(
      0,
      Math.min(
        px + 8,
        this.canvasTarget.clientWidth - this.tooltip.offsetWidth,
      ),
    );
    this.tooltip.style.left = `${left}px`;
    this.tooltip.style.top = "4px";
  }

  hideHover() {
    this.hoverLine?.attr("visibility", "hidden");
    this.tooltip?.classList.add("hidden");
  }

  // --- internals ---

  selectedIndex() {
    return Math.min(
      Number(this.scrubberTarget.value),
      this.periods.length - 1,
    );
  }

  seriesValue(period) {
    const m = period.m;
    if (this.lensValue === "sv") return Number(m.inc) - Number(m.sp);
    return Number(m[this.lensValue]);
  }

  highlightLens() {
    this.lensTabTargets.forEach((tab) => {
      tab.dataset.active = String(tab.dataset.lens === this.lensValue);
    });
  }

  renderAxis() {
    const first = this.periods[0];
    const last = this.periods[this.periods.length - 1];
    if (!first || !last) return;
    const spans = [first, last].map((p) => {
      const span = document.createElement("span");
      span.textContent = p.s.slice(0, 4);
      return span;
    });
    this.axisTarget.replaceChildren(...spans);
  }

  renderChart() {
    const width = this.canvasTarget.clientWidth;
    const height = this.canvasTarget.clientHeight;
    if (width === 0 || this.periods.length === 0) return;

    const values = this.periods.map((p) => this.seriesValue(p));
    const x = d3
      .scaleLinear()
      .domain([0, values.length - 1])
      .range([0, width]);
    const y = d3
      .scaleLinear()
      .domain([Math.min(0, d3.min(values)), d3.max(values)])
      .nice()
      .range([height - 4, 4]);

    const line = d3
      .line()
      .x((_, i) => x(i))
      .y((v) => y(v));
    const area = d3
      .area()
      .x((_, i) => x(i))
      .y0(height)
      .y1((v) => y(v));

    this.canvasTarget.replaceChildren();
    const svg = d3
      .select(this.canvasTarget)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("role", "img");

    svg
      .append("path")
      .datum(values)
      .attr("d", area)
      .attr("fill", "var(--color-indigo-500, #6366f1)")
      .attr("fill-opacity", 0.12);
    svg
      .append("path")
      .datum(values)
      .attr("d", line)
      .attr("fill", "none")
      .attr("stroke", "var(--color-indigo-500, #6366f1)")
      .attr("stroke-width", 2.25)
      .attr("stroke-linecap", "round");

    this.scrubLine = svg
      .append("line")
      .attr("y1", 0)
      .attr("y2", height)
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", 0.4)
      .attr("stroke-dasharray", "3 3");

    this.hoverLine = svg
      .append("line")
      .attr("y1", 0)
      .attr("y2", height)
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", 0.15)
      .attr("visibility", "hidden");

    // replaceChildren() above wiped any previous tooltip — recreate it each
    // render. The canvas div is `relative`; the tooltip positions inside it.
    this.tooltip = document.createElement("div");
    this.tooltip.className =
      "pointer-events-none absolute hidden rounded-md border border-primary bg-container px-2 py-1 text-xs text-primary shadow-xs privacy-sensitive";
    this.canvasTarget.appendChild(this.tooltip);

    this.xScale = x;
    this.positionScrubLine();
  }

  positionScrubLine() {
    if (!this.scrubLine) return;
    const px = this.xScale(this.selectedIndex());
    this.scrubLine.attr("x1", px).attr("x2", px);
  }

  renderSelection(index) {
    const period = this.periods[index];
    if (!period) return;
    this.renderMetricColumn(period);
    this.renderInspector(period);
  }

  renderMetricColumn(period) {
    const m = period.m;
    const rows = [
      ["net_worth", this.formatter.format(Number(m.nw))],
      ["liquid_cash", this.formatter.format(Number(m.lc))],
      ["portfolio_value", this.formatter.format(Number(m.pv))],
      ["debt_balance", this.formatter.format(Number(m.db))],
      ["runway", this.runwayText(m.rd)],
      ["saved_per_month", this.formatter.format(Number(m.inc) - Number(m.sp))],
    ];
    const heading = document.createElement("div");
    heading.className =
      "py-2 text-xs font-semibold uppercase tracking-wide text-subdued";
    heading.textContent = period.s.slice(0, 7);
    const rowNodes = rows.map(([key, value]) => {
      const row = document.createElement("div");
      row.className = "flex items-baseline justify-between py-2";
      const dt = document.createElement("dt");
      dt.className = "text-sm text-secondary";
      dt.textContent = this.metricLabel(key);
      const dd = document.createElement("dd");
      dd.className = "text-sm font-semibold text-primary privacy-sensitive";
      dd.textContent = value;
      row.append(dt, dd);
      return row;
    });
    this.metricColumnTarget.replaceChildren(heading, ...rowNodes);
  }

  renderInspector(period) {
    const m = period.m;
    const count = (period.aa || []).length;
    const label = document.createElement("strong");
    label.className = "text-primary";
    label.textContent = period.s.slice(0, 7);
    const chips = [
      [this.labels.inspector.income, Number(m.inc)],
      [this.labels.inspector.spending, Number(m.sp)],
      [this.labels.inspector.net, Number(m.inc) - Number(m.sp)],
    ].map(([name, value]) => {
      const chip = document.createElement("span");
      chip.className =
        "inline-flex items-center gap-1 rounded-md border border-secondary px-2 py-0.5 privacy-sensitive";
      chip.textContent = `${name} ${this.formatter.format(value)}`;
      return chip;
    });
    const active = document.createElement("span");
    active.className = "text-subdued";
    active.textContent = this.pluralize(
      this.labels.inspector.active_assumptions,
      count,
    );
    this.inspectorTarget.replaceChildren(label, ...chips, active);
  }

  metricLabel(key) {
    return this.labels.metrics[key] || key;
  }

  runwayText(runwayDays) {
    const days = Number(runwayDays);
    if (days >= UNBOUNDED_RUNWAY_DAYS) {
      return this.labels.metrics.runway_unbounded || "";
    }
    return this.pluralize(
      this.labels.metrics.runway_months,
      Math.round(days / 30),
    );
  }

  pluralize(templates, count) {
    const template = (count === 1 ? templates?.one : templates?.other) || "";
    return template.replace("%{count}", count);
  }
}
