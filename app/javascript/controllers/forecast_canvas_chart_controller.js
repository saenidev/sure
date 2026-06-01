import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

const parseDate = d3.timeParse("%Y-%m-%d");
const formatIsoDate = d3.timeFormat("%Y-%m-%d");
const formatShortDate = d3.timeFormat("%b %-d, %Y");

export default class extends Controller {
  static targets = [
    "chart",
    "detailPanel",
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
    "viewportLabel",
  ];

  static values = {
    payload: Object,
  };

  connect() {
    this.payload = this.#normalizePayload(this.payloadValue);
    const initialState = this.#stateFromUrl();
    this.selectedMetric = initialState.metric || this.payload.metrics[0]?.key;
    this.selectedRange = initialState.range || "3y";
    this.activeSeriesIds = new Set(
      this.payload.series.map((series) => series.id),
    );
    this.localEvents = [];
    this.selectedSeriesId = initialState.series || null;
    this.selectedEventKey = initialState.event || null;

    this.#installResizeObserver();
    this.#renderSource();
    this.#renderLegend();
    this.#renderEvents();
    this.#renderEmptyDetails();
    this.#syncControls();
    this.#renderChart();
    this.#applyInitialSelectionFromUrl();
    this.#syncUrlState();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
  }

  selectMetric(event) {
    this.selectedMetric = event.currentTarget.dataset.metric;
    this.#syncControls();
    this.#renderChart();
    this.#syncUrlState();
  }

  selectRange(event) {
    this.selectedRange = event.currentTarget.dataset.range;
    this.#syncControls();
    this.#renderChart();
    this.#syncUrlState();
  }

  zoomIn() {
    this.#zoomBy(1.4);
  }

  zoomOut() {
    this.#zoomBy(1 / 1.4);
  }

  resetZoom() {
    if (!this.overlay || !this.zoom) return;

    this.overlay
      .transition()
      .duration(160)
      .call(this.zoom.transform, d3.zoomIdentity);
  }

  toggleSeries(event) {
    const seriesId = event.currentTarget.dataset.seriesId;
    if (!seriesId) return;

    if (event.currentTarget.checked) {
      this.activeSeriesIds.add(seriesId);
    } else {
      this.activeSeriesIds.delete(seriesId);
      if (this.selectedSeriesId === seriesId) this.selectedSeriesId = null;
    }

    this.#renderChart();
    this.#syncUrlState();
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
    this.#appendScenarioTarget(body.scenario);
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

  async forkScenario(event) {
    event.preventDefault();

    const form = event.currentTarget;
    const url = this.payload.draft_options?.fork_url;
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
      this.#renderFormErrors(form, body.errors || {});
      return;
    }

    this.payload.stale = true;
    this.#appendScenarioTarget(body.scenario);
    this.#renderSource();
    this.#renderForkSuccess(body.scenario, body.message);
  }

  refreshDraftScenarioTarget(event) {
    this.#refreshDraftScenarioTarget(event.currentTarget.closest("form"));
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

  #stateFromUrl() {
    if (typeof window === "undefined") return {};

    const searchParams = new URL(window.location.href).searchParams;
    const state = {};
    const metric = searchParams.get("metric");
    const range = searchParams.get("range");
    const series = searchParams.get("series");
    const event = searchParams.get("event");

    if (this.payload.metrics.some((candidate) => candidate.key === metric)) {
      state.metric = metric;
    }

    if (
      this.rangeButtonTargets.some((button) => button.dataset.range === range)
    ) {
      state.range = range;
    }

    if (this.#seriesById(series)) {
      state.series = series;
    }

    if (this.#eventByKey(event)) {
      state.event = event;
      state.series = undefined;
    }

    return state;
  }

  #applyInitialSelectionFromUrl() {
    if (this.selectedEventKey) {
      const event = this.#eventByKey(this.selectedEventKey);
      if (event) {
        this.#selectEvent(event);
        return;
      }

      this.selectedEventKey = null;
    }

    if (this.selectedSeriesId) {
      const series = this.#seriesById(this.selectedSeriesId);
      if (series) {
        this.#selectStack(series);
        return;
      }

      this.selectedSeriesId = null;
    }

    this.#syncSelectionStyles();
  }

  #syncUrlState() {
    if (typeof window === "undefined" || !window.history?.replaceState) return;

    const url = new URL(window.location.href);
    const searchParams = url.searchParams;

    if (this.selectedMetric) {
      searchParams.set("metric", this.selectedMetric);
    } else {
      searchParams.delete("metric");
    }

    if (this.selectedRange) {
      searchParams.set("range", this.selectedRange);
    } else {
      searchParams.delete("range");
    }

    if (this.selectedSeriesId) {
      searchParams.set("series", this.selectedSeriesId);
    } else {
      searchParams.delete("series");
    }

    if (this.selectedEventKey) {
      searchParams.set("event", this.selectedEventKey);
      searchParams.delete("series");
    } else {
      searchParams.delete("event");
    }

    window.history.replaceState(window.history.state, "", url);
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
      const row = document.createElement("div");
      row.className =
        "flex items-center justify-between gap-2 rounded-md border border-transparent px-2 py-1.5";
      row.setAttribute("data-forecast-canvas-series-id", series.id);
      this.#toggleSelectedRow(row, this.#isSelectedSeries(series));

      const label = document.createElement("label");
      label.className =
        "flex min-w-0 flex-1 items-center gap-3 text-sm text-primary";

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
      row.append(label);

      if (series.prototype || series.preview) {
        const badge = document.createElement("span");
        badge.className = "text-secondary text-xs";
        badge.textContent = this.payload.labels?.prototype || "Preview";
        row.append(badge);
      }

      const inspect = document.createElement("button");
      inspect.type = "button";
      inspect.className =
        "shrink-0 rounded-md px-2 py-1 text-secondary text-xs hover:bg-surface-inset hover:text-primary";
      inspect.textContent =
        this.payload.labels?.inspector?.inspect || "Inspect";
      inspect.setAttribute("data-forecast-canvas-series-inspect", series.id);
      inspect.setAttribute(
        "aria-pressed",
        this.#isSelectedSeries(series) ? "true" : "false",
      );
      inspect.addEventListener("click", () => this.#selectStack(series));

      if (!(series.prototype || series.preview)) {
        row.append(inspect);
      }

      this.legendTarget.append(row);
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
      const eventKey = this.#eventKey(event);
      const row = document.createElement("button");
      row.type = "button";
      row.className =
        "flex w-full items-start gap-2 rounded-md border border-transparent px-2 py-1.5 text-left text-sm hover:bg-surface-inset";
      row.setAttribute("data-forecast-canvas-event-key", eventKey);
      row.setAttribute(
        "aria-pressed",
        this.#isSelectedEvent(event) ? "true" : "false",
      );
      this.#toggleSelectedRow(row, this.#isSelectedEvent(event));
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
    this.baseXScale = null;
    this.xScale = null;
    this.zoom = null;
    this.overlay = null;
    this.lineLayer = null;
    this.eventLayer = null;

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
      this.#renderViewportLabel();
      return;
    }

    if (allPoints.length < 2) {
      this.#renderEmptyChart(
        svg,
        width,
        height,
        this.payload.labels?.metric_empty,
      );
      this.#renderViewportLabel();
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

    this.zoom = d3
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
      .call(this.zoom)
      .on("mousemove", (event) => this.#trackPointer(event))
      .on("mouseleave", () => this.focusLayer.style("display", "none"))
      .on("click", (event) => this.#handleOverlayClick(event));

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

    if (visibleValues.length === 0) {
      this.#renderViewportLabel();
      return;
    }

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
      .attr("stroke-width", (series) =>
        this.#isSelectedSeries(series) ? 3.5 : 2.5,
      )
      .attr("opacity", (series) =>
        this.selectedSeriesId && !this.#isSelectedSeries(series) ? 0.32 : 0.95,
      )
      .attr("stroke-dasharray", (series) =>
        series.prototype || series.preview ? "6 4" : null,
      )
      .attr("d", (series) => line(series.points));

    this.#updateEvents();
    this.#renderViewportLabel();
    this.#syncSelectionStyles();
  }

  #updateEvents() {
    const domain = this.xScale.domain();
    const events = [...this.payload.events, ...this.localEvents].filter(
      (event) => event.dateObject >= domain[0] && event.dateObject <= domain[1],
    );

    this.eventLayer
      .selectAll("line.forecast-event")
      .data(events, (event) => this.#eventKey(event))
      .join("line")
      .attr("class", "forecast-event")
      .attr("x1", (event) => this.xScale(event.dateObject))
      .attr("x2", (event) => this.xScale(event.dateObject))
      .attr("y1", 0)
      .attr("y2", this.innerHeight)
      .attr("stroke", (event) => event.color || "var(--color-gray-500)")
      .attr("stroke-width", (event) => (this.#isSelectedEvent(event) ? 3.5 : 2))
      .attr("stroke-dasharray", "4 4")
      .attr("stroke-linecap", "round")
      .attr("opacity", (event) =>
        this.selectedEventKey && !this.#isSelectedEvent(event) ? 0.35 : 0.85,
      )
      .attr("pointer-events", "none");
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

  #zoomBy(factor) {
    if (!this.overlay || !this.zoom) return;

    this.overlay
      .transition()
      .duration(160)
      .call(this.zoom.scaleBy, factor, [
        this.innerWidth / 2,
        this.innerHeight / 2,
      ]);
  }

  #renderViewportLabel() {
    if (!this.hasViewportLabelTarget) return;

    const domain = this.xScale?.domain?.();
    if (!domain?.[0] || !domain?.[1]) {
      this.viewportLabelTarget.textContent =
        this.payload.labels?.viewport_empty || "";
      return;
    }

    this.viewportLabelTarget.textContent = (
      this.payload.labels?.viewport_window || "%{start_date} to %{end_date}"
    )
      .replace("%{start_date}", formatShortDate(domain[0]))
      .replace("%{end_date}", formatShortDate(domain[1]));
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

  #handleOverlayClick(event) {
    if (event.defaultPrevented) return;

    const nearestEvent = this.#nearestEventToPointer(event);
    if (nearestEvent) {
      this.#selectEvent(nearestEvent);
      return;
    }

    this.#addDraftMarker(event);
  }

  #nearestEventToPointer(event) {
    const [x, y] = d3.pointer(event);
    if (x < 0 || x > this.innerWidth || y < 0 || y > this.innerHeight) {
      return null;
    }

    const domain = this.xScale.domain();
    const hitRadius = 12;
    let nearest = null;

    [...this.payload.events, ...this.localEvents].forEach((candidate) => {
      if (
        !candidate.dateObject ||
        candidate.dateObject < domain[0] ||
        candidate.dateObject > domain[1]
      ) {
        return;
      }

      const xPosition = this.xScale(candidate.dateObject);
      const distance = Math.abs(xPosition - x);
      if (!Number.isFinite(distance) || distance > hitRadius) return;

      if (!nearest || distance < nearest.distance) {
        nearest = { event: candidate, distance };
      }
    });

    return nearest?.event || null;
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
    this.#setSelectedSeries(series);
    this.selectedDateTarget.textContent = formatShortDate(point.dateObject);
    this.selectedValueTarget.textContent =
      point.formatted || this.#formatValue(point.value);
    this.selectedSeriesTarget.textContent = series.label;
    this.#renderPointDetails(series, point);
  }

  #selectEvent(event) {
    this.#setSelectedEvent(event);
    this.selectedDateTarget.textContent = formatShortDate(event.dateObject);
    this.selectedValueTarget.textContent = event.label;
    this.selectedSeriesTarget.textContent = event.scenario || event.kind || "";
    if (event.kind !== "draft" && this.hasDraftPanelTarget) {
      this.draftPanelTarget.replaceChildren();
    }
    this.#renderEventDetails(event);
  }

  #selectStack(series) {
    this.#setSelectedSeries(series);
    const stack = this.payload.stacks?.find((candidate) => {
      return (
        candidate.id === series.id ||
        candidate.stack_key === series.stack_key ||
        candidate.stack_key === series.id
      );
    }) || {
      id: series.id,
      label: series.label,
      stack_key: series.stack_key,
      scenario_ids: series.scenario_ids || [],
      source_scenario_ids: series.scenario_ids || [],
      scenario_names: [],
      feasibility_status: series.feasibility_status,
      end_values: {},
      low_points: {},
      goal_status_counts: {},
      risk_flags: [],
    };

    this.selectedDateTarget.textContent =
      this.payload.labels?.inspector?.stack_heading || "Scenario stack";
    this.selectedValueTarget.textContent = stack.label;
    this.selectedSeriesTarget.textContent =
      stack.feasibility_status || series.feasibility_status || "";
    this.#renderStackDetails(stack, series);
  }

  #setSelectedSeries(series) {
    const seriesId = String(series.id || series.stack_key || "");
    const changed =
      this.selectedSeriesId !== seriesId || this.selectedEventKey !== null;
    this.selectedSeriesId = seriesId;
    this.selectedEventKey = null;
    if (changed) this.#syncSelectionStyles();
    this.#syncUrlState();
  }

  #setSelectedEvent(event) {
    const eventKey = this.#eventKey(event);
    const changed =
      this.selectedEventKey !== eventKey || this.selectedSeriesId !== null;
    this.selectedSeriesId = null;
    this.selectedEventKey = eventKey;
    if (changed) this.#syncSelectionStyles();
    this.#syncUrlState();
  }

  #syncSelectionStyles() {
    this.#syncSeriesSelectionStyles();
    this.#syncEventSelectionStyles();
  }

  #syncSeriesSelectionStyles() {
    if (this.lineLayer) {
      this.lineLayer
        .selectAll("path.forecast-line")
        .attr("stroke-width", (series) =>
          this.#isSelectedSeries(series) ? 3.5 : 2.5,
        )
        .attr("opacity", (series) =>
          this.selectedSeriesId && !this.#isSelectedSeries(series)
            ? 0.32
            : 0.95,
        );
    }

    this.legendTarget
      .querySelectorAll("[data-forecast-canvas-series-id]")
      .forEach((row) => {
        const selected =
          row.dataset.forecastCanvasSeriesId === this.selectedSeriesId;
        this.#toggleSelectedRow(row, selected);
        row
          .querySelector("[data-forecast-canvas-series-inspect]")
          ?.setAttribute("aria-pressed", selected ? "true" : "false");
      });
  }

  #syncEventSelectionStyles() {
    if (this.eventLayer) {
      this.eventLayer
        .selectAll("line.forecast-event")
        .attr("stroke-width", (event) =>
          this.#isSelectedEvent(event) ? 3.5 : 2,
        )
        .attr("opacity", (event) =>
          this.selectedEventKey && !this.#isSelectedEvent(event) ? 0.35 : 0.85,
        );
    }

    this.eventListTarget
      .querySelectorAll("[data-forecast-canvas-event-key]")
      .forEach((row) => {
        const selected =
          row.dataset.forecastCanvasEventKey === this.selectedEventKey;
        this.#toggleSelectedRow(row, selected);
        row.setAttribute("aria-pressed", selected ? "true" : "false");
      });
  }

  #toggleSelectedRow(row, selected) {
    row.classList.toggle("bg-surface-inset", selected);
    row.classList.toggle("border-primary", selected);
    row.classList.toggle("border-transparent", !selected);
  }

  #isSelectedSeries(series) {
    if (!this.selectedSeriesId) return false;

    return [series.id, series.stack_key]
      .filter(Boolean)
      .map((identifier) => String(identifier))
      .includes(this.selectedSeriesId);
  }

  #isSelectedEvent(event) {
    return this.selectedEventKey === this.#eventKey(event);
  }

  #eventKey(event) {
    if (event.id) return `event:${event.id}`;

    return `${event.kind || "event"}:${event.date || ""}:${event.label || ""}`;
  }

  #seriesById(seriesId) {
    if (!seriesId) return null;

    return this.payload.series.find((series) => {
      return [series.id, series.stack_key]
        .filter(Boolean)
        .map((identifier) => String(identifier))
        .includes(seriesId);
    });
  }

  #eventByKey(eventKey) {
    if (!eventKey) return null;

    return [...this.payload.events, ...this.localEvents].find((event) => {
      return this.#eventKey(event) === eventKey;
    });
  }

  #renderEmptyDetails() {
    if (!this.hasDetailPanelTarget) return;

    this.detailPanelTarget.replaceChildren();
  }

  #renderPointDetails(series, point) {
    if (!this.hasDetailPanelTarget) return;

    const labels = this.payload.labels?.inspector || {};
    const fragment = document.createDocumentFragment();

    fragment.append(
      this.#detailsHeading(labels.metrics_heading || "Metric values"),
    );

    const delta = document.createElement("div");
    delta.className = "rounded-md bg-surface px-3 py-2 text-sm text-primary";
    delta.append(
      this.#mutedText(labels.delta_label || "Vs baseline"),
      this.#strongText(point.formatted_delta || labels.no_delta || "Baseline"),
    );
    fragment.append(delta);

    const metrics = document.createElement("dl");
    metrics.className = "grid grid-cols-2 gap-2";
    this.payload.metrics.forEach((metric) => {
      const matchingPoint = (series.metrics[metric.key] || []).find(
        (candidate) => candidate.date === point.date,
      );
      if (!matchingPoint) return;

      metrics.append(
        this.#metricBlock(
          metric.label,
          matchingPoint.formatted || this.#formatValue(matchingPoint.value),
        ),
      );
    });
    fragment.append(metrics);

    const stack = this.payload.stacks?.find((candidate) => {
      return (
        candidate.id === series.id || candidate.stack_key === series.stack_key
      );
    });
    if (stack) {
      const inspect = document.createElement("button");
      inspect.type = "button";
      inspect.className =
        "w-full rounded-md border border-primary px-3 py-2 text-left text-primary text-sm hover:bg-surface-inset";
      inspect.textContent = `${labels.inspect || "Inspect"} ${stack.label}`;
      inspect.addEventListener("click", () => this.#selectStack(series));
      fragment.append(inspect);
    }

    this.detailPanelTarget.replaceChildren(fragment);
  }

  #renderEventDetails(event) {
    if (!this.hasDetailPanelTarget) return;

    const labels = this.payload.labels?.inspector || {};
    const fragment = document.createDocumentFragment();
    fragment.append(
      this.#detailsHeading(labels.event_heading || "Event details"),
    );

    const rows = [
      [labels.status || "Status", event.status_label || event.status],
      [
        labels.window || "Window",
        event.window_label || formatShortDate(event.dateObject),
      ],
      [
        labels.recurrence || "Recurrence",
        event.recurrence_label || (event.recurring ? "" : labels.one_time),
      ],
      [labels.effect || "Effect", event.effect_label || event.effect_type],
      [labels.amount || "Amount", event.formatted_amount],
      [labels.scenario || "Scenario", event.scenario],
    ].filter(([, value]) => value);

    const list = document.createElement("dl");
    list.className = "space-y-2";
    rows.forEach(([label, value]) =>
      list.append(this.#detailRow(label, value)),
    );
    fragment.append(list);

    if (event.edit_url) {
      const link = document.createElement("a");
      link.href = event.edit_url;
      link.className =
        "inline-flex items-center justify-center rounded-md border border-primary px-3 py-2 text-primary text-sm hover:bg-surface-inset";
      link.textContent = labels.edit_event || "Edit event";
      fragment.append(link);
    }

    this.detailPanelTarget.replaceChildren(fragment);
  }

  #renderStackDetails(stack, series) {
    if (!this.hasDetailPanelTarget) return;

    const labels = this.payload.labels?.inspector || {};
    const fragment = document.createDocumentFragment();
    fragment.append(
      this.#detailsHeading(labels.stack_heading || "Scenario stack"),
    );

    const overview = document.createElement("dl");
    overview.className = "space-y-2";
    overview.append(
      this.#detailRow(
        labels.feasibility || "Feasibility",
        stack.feasibility_status || "unknown",
      ),
    );
    if (stack.scenario_names?.length > 0) {
      overview.append(
        this.#detailRow(
          labels.scenario || "Scenario",
          stack.scenario_names.join(" + "),
        ),
      );
    }
    fragment.append(overview);

    fragment.append(
      this.#summaryGroup(
        labels.end_heading || "End of horizon",
        stack.end_values,
      ),
      this.#summaryGroup(
        labels.low_heading || "Lowest point",
        stack.low_points,
      ),
      this.#goalGroup(
        labels.goals_heading || "Goal results",
        stack.goal_status_counts,
      ),
      this.#riskGroup(labels.risks_heading || "Risk flags", stack.risk_flags),
      this.#forkFormForStack(stack, series),
    );

    this.detailPanelTarget.replaceChildren(fragment);
  }

  #detailsHeading(text) {
    const heading = document.createElement("h3");
    heading.className = "text-primary text-sm font-medium";
    heading.textContent = text;
    return heading;
  }

  #mutedText(text) {
    const element = document.createElement("span");
    element.className = "block text-secondary text-xs";
    element.textContent = text;
    return element;
  }

  #strongText(text) {
    const element = document.createElement("span");
    element.className = "block text-primary text-sm font-medium tabular-nums";
    element.textContent = text;
    return element;
  }

  #metricBlock(label, value) {
    const block = document.createElement("div");
    block.className = "rounded-md bg-surface px-3 py-2";

    const term = document.createElement("dt");
    term.className = "text-secondary text-xs";
    term.textContent = label;

    const description = document.createElement("dd");
    description.className =
      "mt-1 text-primary text-sm font-medium tabular-nums";
    description.textContent = value;

    block.append(term, description);
    return block;
  }

  #detailRow(label, value) {
    const row = document.createElement("div");
    row.className = "flex items-start justify-between gap-3 text-sm";

    const term = document.createElement("dt");
    term.className = "text-secondary";
    term.textContent = label;

    const description = document.createElement("dd");
    description.className = "text-right text-primary";
    description.textContent = value;

    row.append(term, description);
    return row;
  }

  #summaryGroup(label, values = {}) {
    const group = document.createElement("section");
    group.className = "space-y-2";
    group.append(this.#detailsHeading(label));

    const entries = Object.entries(values || {}).filter(([, value]) => value);
    if (entries.length === 0) {
      group.append(this.#emptyText());
      return group;
    }

    const grid = document.createElement("dl");
    grid.className = "grid grid-cols-2 gap-2";
    entries.forEach(([key, value]) => {
      grid.append(
        this.#metricBlock(this.#metricLabel(key), value.formatted || value),
      );
    });
    group.append(grid);
    return group;
  }

  #goalGroup(label, counts = {}) {
    const group = document.createElement("section");
    group.className = "space-y-2";
    group.append(this.#detailsHeading(label));

    const entries = Object.entries(counts || {}).filter(
      ([, count]) => count > 0,
    );
    if (entries.length === 0) {
      group.append(this.#emptyText());
      return group;
    }

    const list = document.createElement("div");
    list.className = "flex flex-wrap gap-2";
    entries.forEach(([status, count]) => {
      const pill = document.createElement("span");
      pill.className = "rounded-md bg-surface px-2 py-1 text-secondary text-xs";
      pill.textContent = `${this.#humanize(status)} ${count}`;
      list.append(pill);
    });
    group.append(list);
    return group;
  }

  #riskGroup(label, risks = []) {
    const group = document.createElement("section");
    group.className = "space-y-2";
    group.append(this.#detailsHeading(label));

    if (!risks || risks.length === 0) {
      group.append(this.#emptyText());
      return group;
    }

    const list = document.createElement("div");
    list.className = "flex flex-wrap gap-2";
    risks.forEach((risk) => {
      const pill = document.createElement("span");
      pill.className =
        "rounded-md bg-warning/10 px-2 py-1 text-warning text-xs";
      pill.textContent = this.#humanize(risk);
      list.append(pill);
    });
    group.append(list);
    return group;
  }

  #forkFormForStack(stack, series) {
    const labels = this.payload.labels?.forks || {};
    const form = document.createElement("form");
    form.className = "space-y-3 border-t border-primary pt-4";
    form.addEventListener("submit", (event) => this.forkScenario(event));

    const sourceIds = stack.source_scenario_ids || stack.scenario_ids || [];
    if (sourceIds.length === 1) {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = "source_scenario_id";
      input.value = sourceIds[0];
      form.append(input);
    } else if (sourceIds.length > 1) {
      sourceIds.forEach((sourceId) => {
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = "source_scenario_ids[]";
        input.value = sourceId;
        form.append(input);
      });
    } else {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = "source";
      input.value = "baseline";
      form.append(input);
    }

    form.append(
      this.#detailsHeading(labels.heading || "Fork scenario"),
      this.#readonlyField(
        labels.source || "Source",
        sourceIds.length > 0
          ? stack.label
          : labels.baseline || series.label || "Baseline",
      ),
    );

    const field = document.createElement("label");
    field.className = "block space-y-1";

    const label = document.createElement("span");
    label.className = "text-primary text-sm font-medium";
    label.textContent = labels.name || "Name";

    const input = document.createElement("input");
    input.className =
      "w-full rounded-md border border-primary bg-container px-3 py-2 text-primary text-sm";
    input.name = "name";
    input.required = true;
    input.value = `${labels.default_name || "Canvas scenario"} - ${stack.label}`;

    field.append(label, input);
    form.append(field);

    if (sourceIds.length > 0) {
      const note = document.createElement("p");
      note.className = "text-secondary text-xs";
      note.textContent = labels.disabled_note || "";
      form.append(note);
    }

    const errors = document.createElement("div");
    errors.className =
      "hidden rounded-md border border-destructive bg-destructive/10 px-3 py-2 text-destructive text-xs";
    errors.dataset.forecastCanvasFormErrors = "true";
    form.append(errors);

    const actions = document.createElement("div");
    actions.className = "flex justify-end";

    const submit = document.createElement("button");
    submit.type = "submit";
    submit.className =
      "inline-flex items-center justify-center rounded-md button-bg-primary px-3 py-2 text-inverse text-sm font-medium hover:button-bg-primary-hover";
    submit.textContent = labels.save || "Create fork";

    actions.append(submit);
    form.append(actions);
    return form;
  }

  #readonlyField(label, value) {
    const wrapper = document.createElement("div");
    wrapper.className = "rounded-md bg-surface px-3 py-2";
    wrapper.append(this.#mutedText(label), this.#strongText(value));
    return wrapper;
  }

  #emptyText() {
    const text = document.createElement("p");
    text.className = "text-secondary text-sm";
    text.textContent = this.payload.labels?.inspector?.none || "None";
    return text;
  }

  #metricLabel(key) {
    return (
      this.payload.metrics.find((metric) => metric.key === key)?.label ||
      this.#humanize(key)
    );
  }

  #humanize(value) {
    return String(value || "")
      .replaceAll("_", " ")
      .replace(/\b\w/g, (character) => character.toUpperCase());
  }

  #appendScenarioTarget(scenario) {
    if (!scenario?.id || !this.payload.draft_options) return;

    const targets = this.payload.draft_options.scenario_targets || [];
    if (targets.some((target) => target.id === scenario.id)) return;

    targets.push(scenario);
    this.payload.draft_options.scenario_targets = targets;
  }

  #renderForkSuccess(scenario, message) {
    if (!this.hasDetailPanelTarget) return;

    const labels = this.payload.labels?.forks || {};
    const fragment = document.createDocumentFragment();
    fragment.append(this.#detailsHeading(labels.heading || "Fork scenario"));

    const notice = document.createElement("div");
    notice.className = "rounded-md border border-primary bg-surface px-3 py-2";
    notice.append(
      this.#strongText(scenario.name),
      this.#mutedText(message || labels.created || "Scenario created."),
    );
    fragment.append(notice);

    if (scenario.edit_url) {
      const link = document.createElement("a");
      link.href = scenario.edit_url;
      link.className =
        "inline-flex items-center justify-center rounded-md border border-primary px-3 py-2 text-primary text-sm hover:bg-surface-inset";
      link.textContent = labels.edit_scenario || "Edit scenario";
      fragment.append(link);
    }

    this.detailPanelTarget.replaceChildren(fragment);
  }

  #renderFormErrors(form, errors) {
    const target = form.querySelector("[data-forecast-canvas-form-errors]");
    if (!target) return;

    const messages = Object.entries(errors).flatMap(([field, fieldErrors]) => {
      return fieldErrors.map((message) => `${field} ${message}`);
    });
    target.textContent = messages.join(" ");
    target.classList.toggle("hidden", messages.length === 0);
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
    this.#syncScenarioSelect(fragment);
    this.#refreshDraftScenarioTarget(fragment);
    this.draftPanelTarget.replaceChildren(fragment);
  }

  #syncScenarioSelect(fragment) {
    const select = fragment.querySelector(
      "[name='forecast_event[scenario_target]']",
    );
    if (!select) return;

    const globalOption = select
      .querySelector("option[value='']")
      ?.cloneNode(true);
    const newScenarioOption = select
      .querySelector("[data-forecast-canvas-new-scenario-option]")
      ?.cloneNode(true);
    select.replaceChildren();
    if (globalOption) select.append(globalOption);

    (this.payload.draft_options?.scenario_targets || []).forEach((scenario) => {
      const option = document.createElement("option");
      option.value = scenario.id;
      option.textContent = scenario.status_label
        ? `${scenario.label || scenario.name} (${scenario.status_label})`
        : scenario.label || scenario.name;
      select.append(option);
    });

    if (newScenarioOption) select.append(newScenarioOption);
  }

  #refreshDraftScenarioTarget(container) {
    if (!container) return;

    const select = container.querySelector(
      "[name='forecast_event[scenario_target]']",
    );
    const field = container.querySelector(
      "[data-forecast-canvas-new-scenario-field]",
    );
    if (!select || !field) return;

    const visible =
      select.value ===
      (this.payload.draft_options?.new_scenario_value || "__new__");
    field.classList.toggle("hidden", !visible);
    field.querySelectorAll("input, select, textarea").forEach((input) => {
      input.disabled = !visible;
      input.required = visible;
    });
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
