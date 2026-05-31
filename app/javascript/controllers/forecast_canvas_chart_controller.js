import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

const parseDate = d3.timeParse("%Y-%m-%d");
const formatIsoDate = d3.timeFormat("%Y-%m-%d");
const formatShortDate = d3.timeFormat("%b %-d, %Y");

export default class extends Controller {
  static targets = [
    "chart",
    "draftPanel",
    "draftTemplate",
    "eventList",
    "inspector",
    "legend",
    "metricButton",
    "rangeButton",
    "selectedDate",
    "selectedSeries",
    "selectedValue",
    "sourceLabel",
  ];

  static values = {
    payload: Object,
  };

  connect() {
    this.payload = this.#normalizePayload(this.payloadValue);
    this.selectedMetric = this.payload.metrics[0]?.key;
    this.selectedRange = "3y";
    this.activeSeriesIds = new Set(
      this.payload.series.map((series) => series.id),
    );
    this.localEvents = [];

    this.#installResizeObserver();
    this.#renderSource();
    this.#renderLegend();
    this.#renderEvents();
    this.#syncControls();
    this.#renderChart();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
  }

  selectMetric(event) {
    this.selectedMetric = event.currentTarget.dataset.metric;
    this.#syncControls();
    this.#renderChart();
  }

  selectRange(event) {
    this.selectedRange = event.currentTarget.dataset.range;
    this.#syncControls();
    this.#renderChart();
  }

  toggleSeries(event) {
    const seriesId = event.currentTarget.dataset.seriesId;
    if (!seriesId) return;

    if (event.currentTarget.checked) {
      this.activeSeriesIds.add(seriesId);
    } else {
      this.activeSeriesIds.delete(seriesId);
    }

    this.#renderChart();
  }

  async saveDraft(event) {
    event.preventDefault();

    const form = event.currentTarget;
    const url = this.payload.draft_options?.create_event_url;
    if (!url) return;

    const response = await fetch(url, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token":
          document.querySelector("meta[name='csrf-token']")?.content || "",
      },
      body: new FormData(form),
    });
    const body = await response.json();

    if (!response.ok) {
      this.#renderDraftErrors(form, body.errors || {});
      return;
    }

    const savedEvent = {
      ...body.event,
      dateObject: parseDate(body.event.date),
    };
    this.localEvents = this.localEvents.filter((candidate) => {
      return candidate.kind !== "draft";
    });
    this.payload.events.push(savedEvent);
    this.payload.stale = true;
    this.#renderSource();
    this.#renderEvents();
    this.#updateEvents();
    this.#selectEvent(savedEvent);
    this.draftPanelTarget.replaceChildren();
  }

  #normalizePayload(payload) {
    return {
      ...payload,
      series: (payload.series || []).map((series) => ({
        ...series,
        metrics: Object.fromEntries(
          Object.entries(series.metrics || {}).map(([metric, points]) => [
            metric,
            points
              .map((point) => ({
                ...point,
                dateObject: parseDate(point.date),
              }))
              .filter(
                (point) => point.dateObject && Number.isFinite(point.value),
              )
              .sort((left, right) =>
                d3.ascending(left.dateObject, right.dateObject),
              ),
          ]),
        ),
      })),
      events: (payload.events || [])
        .map((event) => ({ ...event, dateObject: parseDate(event.date) }))
        .filter((event) => event.dateObject)
        .sort((left, right) => d3.ascending(left.dateObject, right.dateObject)),
    };
  }

  #installResizeObserver() {
    this.resizeObserver = new ResizeObserver(() => this.#renderChart());
    this.resizeObserver.observe(this.chartTarget);
  }

  #renderSource() {
    if (!this.hasSourceLabelTarget) return;

    const labels = this.payload.labels || {};
    const sourceLabels = labels.source || {};
    const pieces = [
      this.payload.preview ? labels.preview : sourceLabels[this.payload.source],
    ].filter(Boolean);
    if (this.payload.generated_label) pieces.push(this.payload.generated_label);
    if (this.payload.stale && labels.stale) pieces.push(labels.stale);
    this.sourceLabelTarget.textContent = pieces.join(" ");
  }

  #renderLegend() {
    this.legendTarget.replaceChildren();

    this.payload.series.forEach((series) => {
      const label = document.createElement("label");
      label.className =
        "flex items-center justify-between gap-3 text-sm text-primary";

      const left = document.createElement("span");
      left.className = "flex min-w-0 items-center gap-2";

      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = this.activeSeriesIds.has(series.id);
      checkbox.dataset.seriesId = series.id;
      checkbox.dataset.action = "forecast-canvas-chart#toggleSeries";
      checkbox.className = "rounded border-primary";

      const swatch = document.createElement("span");
      swatch.className = "h-2.5 w-2.5 shrink-0 rounded-full";
      swatch.style.background = series.color;

      const name = document.createElement("span");
      name.className = "min-w-0 truncate";
      name.textContent = series.label;

      left.append(checkbox, swatch, name);
      label.append(left);

      if (series.prototype || series.preview) {
        const badge = document.createElement("span");
        badge.className = "text-secondary text-xs";
        badge.textContent = this.payload.labels?.prototype || "Preview";
        label.append(badge);
      }

      this.legendTarget.append(label);
    });
  }

  #renderEvents() {
    this.eventListTarget.replaceChildren();
    const events = [...this.payload.events, ...this.localEvents].sort(
      (left, right) => d3.ascending(left.dateObject, right.dateObject),
    );

    if (events.length === 0) {
      const empty = document.createElement("p");
      empty.className = "text-secondary text-sm";
      empty.textContent = this.payload.labels?.event_empty || "";
      this.eventListTarget.append(empty);
      return;
    }

    events.slice(0, 8).forEach((event) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className =
        "flex w-full items-start gap-2 rounded-md px-2 py-1.5 text-left text-sm hover:bg-surface-inset";
      row.addEventListener("click", () => {
        this.#selectEvent(event);
      });

      const swatch = document.createElement("span");
      swatch.className = "mt-1 h-2.5 w-2.5 shrink-0 rounded-full";
      swatch.style.background = event.color || "var(--color-gray-500)";

      const copy = document.createElement("span");
      copy.className = "min-w-0";

      const title = document.createElement("span");
      title.className = "block truncate text-primary";
      title.textContent = event.label;

      const date = document.createElement("span");
      date.className = "block text-secondary text-xs";
      date.textContent = formatShortDate(event.dateObject);

      copy.append(title, date);
      row.append(swatch, copy);
      this.eventListTarget.append(row);
    });
  }

  #syncControls() {
    this.metricButtonTargets.forEach((button) => {
      button.setAttribute(
        "aria-pressed",
        button.dataset.metric === this.selectedMetric ? "true" : "false",
      );
    });

    this.rangeButtonTargets.forEach((button) => {
      button.setAttribute(
        "aria-pressed",
        button.dataset.range === this.selectedRange ? "true" : "false",
      );
    });
  }

  #renderChart() {
    const rect = this.chartTarget.getBoundingClientRect();
    const width = Math.max(rect.width, 320);
    const height = Math.max(rect.height, 360);
    const margin = { top: 20, right: 24, bottom: 34, left: 74 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    d3.select(this.chartTarget).selectAll("*").remove();

    const activeSeries = this.#activeSeriesWithMetric();
    const allPoints = activeSeries.flatMap((series) => series.points);

    const svg = d3
      .select(this.chartTarget)
      .append("svg")
      .attr("class", "block h-full w-full")
      .attr("role", "img")
      .attr("viewBox", `0 0 ${width} ${height}`);

    if (activeSeries.length === 0) {
      this.#renderEmptyChart(
        svg,
        width,
        height,
        this.payload.labels?.line_empty,
      );
      return;
    }

    if (allPoints.length < 2) {
      this.#renderEmptyChart(
        svg,
        width,
        height,
        this.payload.labels?.metric_empty,
      );
      return;
    }

    this.svg = svg;
    this.innerWidth = innerWidth;
    this.innerHeight = innerHeight;
    this.plot = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);
    this.grid = this.plot.append("g");
    this.xAxis = this.plot
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`);
    this.yAxis = this.plot.append("g");
    this.eventLayer = this.plot.append("g");
    this.lineLayer = this.plot.append("g");
    this.focusLayer = this.plot.append("g").style("display", "none");

    this.focusLine = this.focusLayer
      .append("line")
      .attr("y1", 0)
      .attr("y2", innerHeight)
      .attr("stroke", "var(--color-gray-400)")
      .attr("stroke-dasharray", "3 3");

    this.focusDot = this.focusLayer
      .append("circle")
      .attr("r", 4)
      .attr("fill", "var(--color-white)")
      .attr("stroke-width", 2);

    const clipId = `forecast-canvas-clip-${Math.random().toString(36).slice(2)}`;
    svg
      .append("defs")
      .append("clipPath")
      .attr("id", clipId)
      .append("rect")
      .attr("width", innerWidth)
      .attr("height", innerHeight);
    this.lineLayer.attr("clip-path", `url(#${clipId})`);

    const domain = this.#domainForRange(allPoints);
    this.baseXScale = d3.scaleTime().domain(domain).range([0, innerWidth]);
    this.xScale = this.baseXScale.copy();
    this.yScale = d3.scaleLinear().range([innerHeight, 0]);

    const zoom = d3
      .zoom()
      .scaleExtent([1, 24])
      .translateExtent([
        [0, 0],
        [innerWidth, innerHeight],
      ])
      .extent([
        [0, 0],
        [innerWidth, innerHeight],
      ])
      .on("zoom", (event) => {
        this.xScale = event.transform.rescaleX(this.baseXScale);
        this.#updatePlot();
      });

    this.overlay = this.plot
      .append("rect")
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "transparent")
      .attr("pointer-events", "all")
      .call(zoom)
      .on("mousemove", (event) => this.#trackPointer(event))
      .on("mouseleave", () => this.focusLayer.style("display", "none"))
      .on("click", (event) => this.#addDraftMarker(event));

    this.#updatePlot();
  }

  #updatePlot() {
    const activeSeries = this.#activeSeriesWithMetric();
    const domain = this.xScale.domain();
    const visibleValues = activeSeries.flatMap((series) =>
      series.points
        .filter(
          (point) =>
            point.dateObject >= domain[0] && point.dateObject <= domain[1],
        )
        .map((point) => point.value),
    );

    if (visibleValues.length === 0) return;

    const [minValue, maxValue] = d3.extent(visibleValues);
    const padding = Math.max(
      (maxValue - minValue) * 0.12,
      Math.abs(maxValue || 1) * 0.03,
      1,
    );
    this.yScale.domain([minValue - padding, maxValue + padding]).nice();

    this.grid
      .call(
        d3
          .axisLeft(this.yScale)
          .ticks(5)
          .tickSize(-this.innerWidth)
          .tickFormat(""),
      )
      .call((group) => group.select(".domain").remove())
      .call((group) =>
        group
          .selectAll(".tick line")
          .attr("stroke", "var(--color-gray-200)")
          .attr("stroke-dasharray", "2 4"),
      );

    this.xAxis
      .call(d3.axisBottom(this.xScale).ticks(6).tickSizeOuter(0))
      .call((group) =>
        group.select(".domain").attr("stroke", "var(--color-gray-300)"),
      )
      .call((group) =>
        group
          .selectAll("text")
          .attr("class", "fill-current text-secondary")
          .style("font-size", "12px"),
      );

    this.yAxis
      .call(
        d3
          .axisLeft(this.yScale)
          .ticks(5)
          .tickFormat((value) => this.#formatAxisValue(value))
          .tickSizeOuter(0),
      )
      .call((group) => group.select(".domain").remove())
      .call((group) =>
        group
          .selectAll("text")
          .attr("class", "fill-current text-secondary")
          .style("font-size", "12px"),
      );

    const line = d3
      .line()
      .defined(
        (point) =>
          point.dateObject >= domain[0] && point.dateObject <= domain[1],
      )
      .x((point) => this.xScale(point.dateObject))
      .y((point) => this.yScale(point.value))
      .curve(d3.curveMonotoneX);

    this.lineLayer
      .selectAll("path.forecast-line")
      .data(activeSeries, (series) => series.id)
      .join(
        (enter) =>
          enter
            .append("path")
            .attr("class", "forecast-line")
            .attr("fill", "none")
            .attr("stroke-width", 2.5)
            .attr("stroke-linecap", "round")
            .attr("stroke-linejoin", "round"),
        (update) => update,
        (exit) => exit.remove(),
      )
      .attr("stroke", (series) => series.color)
      .attr("stroke-dasharray", (series) =>
        series.prototype || series.preview ? "6 4" : null,
      )
      .attr("d", (series) => line(series.points));

    this.#updateEvents();
  }

  #updateEvents() {
    const domain = this.xScale.domain();
    const events = [...this.payload.events, ...this.localEvents].filter(
      (event) => event.dateObject >= domain[0] && event.dateObject <= domain[1],
    );

    this.eventLayer
      .selectAll("line.forecast-event")
      .data(events, (event) => event.id || `${event.label}-${event.date}`)
      .join("line")
      .attr("class", "forecast-event")
      .attr("x1", (event) => this.xScale(event.dateObject))
      .attr("x2", (event) => this.xScale(event.dateObject))
      .attr("y1", 0)
      .attr("y2", this.innerHeight)
      .attr("stroke", (event) => event.color || "var(--color-gray-500)")
      .attr("stroke-width", 1.5)
      .attr("stroke-dasharray", "4 4")
      .attr("opacity", 0.8);
  }

  #activeSeriesWithMetric() {
    return this.payload.series
      .filter((series) => this.activeSeriesIds.has(series.id))
      .map((series) => ({
        ...series,
        points: series.metrics[this.selectedMetric] || [],
      }))
      .filter((series) => series.points.length > 1);
  }

  #renderEmptyChart(svg, width, height, message) {
    svg
      .append("text")
      .attr("x", width / 2)
      .attr("y", height / 2)
      .attr("text-anchor", "middle")
      .attr("class", "fill-current text-secondary")
      .style("font-size", "13px")
      .text(message || "");
  }

  #domainForRange(points) {
    const fullDomain = d3.extent(points, (point) => point.dateObject);
    const activeRangeButton = this.rangeButtonTargets.find(
      (button) => button.dataset.range === this.selectedRange,
    );
    const months = Number.parseInt(activeRangeButton?.dataset.months || "", 10);

    if (!Number.isFinite(months)) return fullDomain;

    const end = fullDomain[1];
    const start = d3.max([fullDomain[0], d3.timeMonth.offset(end, -months)]);
    return [start, end];
  }

  #trackPointer(event) {
    const [x] = d3.pointer(event);
    const date = this.xScale.invert(x);
    const nearest = this.#nearestPoint(date);
    if (!nearest) return;

    const xPosition = this.xScale(nearest.point.dateObject);
    const yPosition = this.yScale(nearest.point.value);

    this.focusLayer.style("display", null);
    this.focusLine.attr("x1", xPosition).attr("x2", xPosition);
    this.focusDot
      .attr("cx", xPosition)
      .attr("cy", yPosition)
      .attr("stroke", nearest.series.color);
    this.#selectPoint(nearest.series, nearest.point);
  }

  #nearestPoint(date) {
    const bisect = d3.bisector((point) => point.dateObject).left;
    let nearest = null;

    this.#activeSeriesWithMetric().forEach((series) => {
      const points = series.points;
      const index = bisect(points, date, 1);
      const candidates = [points[index - 1], points[index]].filter(Boolean);

      candidates.forEach((point) => {
        const distance = Math.abs(point.dateObject - date);
        if (!nearest || distance < nearest.distance) {
          nearest = { series, point, distance };
        }
      });
    });

    return nearest;
  }

  #selectPoint(series, point) {
    this.selectedDateTarget.textContent = formatShortDate(point.dateObject);
    this.selectedValueTarget.textContent =
      point.formatted || this.#formatValue(point.value);
    this.selectedSeriesTarget.textContent = series.label;
  }

  #selectEvent(event) {
    this.selectedDateTarget.textContent = formatShortDate(event.dateObject);
    this.selectedValueTarget.textContent = event.label;
    this.selectedSeriesTarget.textContent = event.scenario || event.kind || "";
  }

  #addDraftMarker(event) {
    const [x] = d3.pointer(event);
    const dateObject = this.xScale.invert(x);
    const marker = {
      date: formatIsoDate(dateObject),
      dateObject,
      label: this.payload.labels?.draft || "",
      kind: "draft",
      color: "var(--color-warning)",
    };

    this.localEvents.push(marker);
    this.#renderEvents();
    this.#updateEvents();
    this.#selectEvent(marker);
    this.#renderDraftForm(marker);
  }

  #renderDraftForm(marker) {
    if (!this.hasDraftPanelTarget || !this.hasDraftTemplateTarget) return;

    const fragment = this.draftTemplateTarget.content.cloneNode(true);
    const startsOn = fragment.querySelector(
      "[data-forecast-canvas-chart-draft-starts-on]",
    );
    const dateLabel = fragment.querySelector(
      "[data-forecast-canvas-chart-draft-date]",
    );
    startsOn.value = marker.date;
    dateLabel.textContent = formatShortDate(marker.dateObject);
    this.draftPanelTarget.replaceChildren(fragment);
  }

  #renderDraftErrors(form, errors) {
    const target = form.querySelector(
      "[data-forecast-canvas-chart-draft-errors]",
    );
    if (!target) return;

    const messages = Object.entries(errors).flatMap(([field, fieldErrors]) => {
      return fieldErrors.map((message) => `${field} ${message}`);
    });
    target.textContent = messages.join(" ");
    target.classList.toggle("hidden", messages.length === 0);
  }

  #formatAxisValue(value) {
    const metric = this.payload.metrics.find(
      (candidate) => candidate.key === this.selectedMetric,
    );
    if (metric?.format === "days") return `${Math.round(value)}d`;

    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: this.payload.currency || "USD",
      notation: "compact",
      maximumFractionDigits: 1,
    }).format(value);
  }

  #formatValue(value) {
    const metric = this.payload.metrics.find(
      (candidate) => candidate.key === this.selectedMetric,
    );
    if (metric?.format === "days") return `${Math.round(value)}d`;

    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: this.payload.currency || "USD",
      maximumFractionDigits: 0,
    }).format(value);
  }
}
