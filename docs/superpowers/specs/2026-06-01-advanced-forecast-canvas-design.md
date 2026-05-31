# Advanced Forecast Canvas Design

Status: Ready for implementation planning
Date: 2026-06-01

## Purpose

Build `/forecast/canvas` into a first-class advanced forecasting workspace for power users. The route remains separate from the guided `/forecast` page, but it must feel native to the forecasting feature: it uses the same forecast runs, scenarios, events, goals, budget plans, and regeneration workflow.

The canvas is the timeline-first interface the user originally envisioned: a zoomable time axis, stock-chart-like forecast lines, scenario layers, event markers, and direct authoring from the graph. It is not a marketing page and not a detached prototype.

## Product Positioning

`/forecast` stays the default guided experience. It continues to organize forecasting into understandable tabs: outlook, what-if, inputs, reconciliation, and history.

`/forecast/canvas` becomes the advanced scenario lab:

- Inspect forecast outcomes on a timeline.
- Compare baseline and scenario stacks visually.
- Add or fork scenario assumptions from the graph.
- Save timeline-authored events into the existing forecasting model.
- Regenerate the forecast using the existing run path.

This creates two compatible mental models:

- Guided mode: "Help me understand and maintain my forecast."
- Canvas mode: "Let me manipulate futures directly on a timeline."

## Approaches Considered

### Recommended: Integrated Advanced Canvas

Keep a separate route but make it first-class. Extract the prototype payload into a read model, split the Stimulus controller into clear responsibilities, and persist user actions through normal Rails controllers and existing forecast records.

Tradeoff: This is more work than polishing the prototype, but it prevents the canvas from becoming a second forecast system.

### Rejected: Read-Only Analysis Canvas

A read-only chart would be easier to stabilize, but it would miss the user's original vision. The graph must be an authoring surface, not only an output surface.

### Rejected: Separate Canvas Forecast Engine

Running different projection logic for the canvas would create drift against the rest of the forecast feature. The canvas should never recompute forecast math independently. It should read persisted run outputs and write normal forecast assumptions, then ask the existing runner to produce new projections.

## User Experience

### Page Layout

The advanced canvas route has three persistent zones:

- Header and controls: route title, freshness state, back link, generate button, metric controls, range controls, and selected scenario stack controls.
- Main chart: zoomable/pannable SVG timeline with projected series, event markers, hover crosshair, click targets, and brushable date range.
- Inspector: context panel for the current selection. It can show a projected point, an event, a scenario stack, a draft event, or an empty state.

The layout should stay dense and operational. No hero treatment. No explanatory marketing copy. The first screen is the working surface.

### Chart Interaction

The chart supports:

- Pan and zoom across the forecast horizon.
- Range presets: 90D, 1Y, 3Y, and All.
- Metric switching for net worth, cash, debt, liquid balance, portfolio value, and cash runway.
- Baseline and scenario stack lines.
- Stable colors per stack during one page session.
- Dashed style for unsaved draft or simulated series.
- Hover crosshair with nearest projected point.
- Click on a projected point to inspect the point.
- Click empty plot space to create a draft marker at that date.
- Event markers aligned to forecast event start dates.

Zoom and pan are local UI state. They do not mutate server state.

### Inspector Modes

The inspector renders one of these modes:

- Point mode: selected date, selected series, selected value, deltas versus baseline, and available metric values for that month.
- Event mode: event name, scenario, date/window, amount/effect, recurrence, status, and links to edit the event in the standard forecast inputs flow.
- Scenario mode: stack label, included scenarios, end-of-horizon metrics, feasibility, risk flags, and goal status summary.
- Draft mode: form for a new forecast event or scenario fork.
- Empty mode: short instruction and current forecast freshness.

Draft mode is the core authoring workflow. A click on the timeline starts a draft at the clicked date, but no record is persisted until the user submits the inspector form.

### Draft Event Flow

Draft event creation supports:

- Name.
- Scenario target: baseline/global event, existing scenario, or new scenario.
- Effect kind using existing `ForecastEvent` effects.
- Start date and optional end date.
- Amount and currency when the effect needs money.
- Recurrence fields when the effect is recurring.
- Account/category selectors when required by existing event behavior.

On submit, Rails validates the payload with the same model constraints as the standard forecast event UI. Success replaces the draft marker with a persisted event marker and surfaces a "Regenerate forecast" action. Failure keeps the draft open and shows field errors.

### Scenario Fork Flow

The canvas supports forking from:

- Baseline.
- Existing scenario.
- Existing scenario stack.

A fork creates a normal `ForecastScenario` in the family, copies or references the selected starting assumptions according to existing model capabilities, and opens the inspector with the scenario selected. The first implementation can make fork creation explicit from an inspector action rather than from drag gestures.

### Regeneration Flow

The canvas does not silently rerun forecasts after every edit. After a persisted draft or scenario fork, the page shows that the current chart is stale and offers the existing generate action.

Generation uses the existing `Forecast::RunsController` path. The canvas should not introduce a separate runner endpoint unless a future project needs background polling with a canvas-specific response format.

### Empty And Preview States

If the family has no completed projection rows, the canvas still renders a preview dataset so users can understand the interaction. It must be clearly labeled as preview data and must not offer to save preview points as real projections.

If the family has planning data but no completed run, the primary action is to generate a forecast. Draft event authoring remains available because assumptions can exist before a run.

## Integration With Existing Forecasting

The canvas is linked naturally from:

- `/forecast` header when a forecast workspace exists.
- Has-run state near the run summary and what-if surfaces.
- Ready/onboarding states as an advanced option after the primary guided action.

Existing forecast tabs remain intact. The canvas can link back into specific standard flows:

- Events edit/new routes for detailed event changes.
- Scenarios index and edit routes for scenario management.
- Runs path for regeneration.
- History/review surfaces for audit and Hermes review.

The route should use the existing app shell, breadcrumbs, privacy mode behavior, design tokens, and `DS::*` primitives where available.

## Architecture

### Controllers

Create `Forecast::CanvasController` for the page:

- Inherits from `Forecast::BaseController`.
- Builds `Forecast::Workspace`.
- Builds `Forecast::CanvasReadModel`.
- Sets breadcrumbs.
- Renders the advanced canvas view.

Create `Forecast::CanvasDraftsController` for canvas-authored writes:

- Inherits from `Forecast::BaseController`.
- Supports event creation from draft payloads.
- Supports scenario fork creation when implemented.
- Returns Turbo Stream or JSON responses according to the request format used by the inspector.
- Scopes every read/write to `@family`.

The existing `ForecastsController#canvas` prototype should be removed or converted to redirect to the namespaced controller. Payload construction should not remain in `ForecastsController`.

### Read Model

Create `Forecast::CanvasReadModel`.

Responsibilities:

- Serialize completed forecast runs into chart-ready series.
- Serialize available metrics and formatting metadata.
- Serialize real forecast events into timeline markers.
- Serialize scenario stack summaries.
- Serialize goal/risk/feasibility summaries needed by the inspector.
- Provide clearly labeled preview data when no completed projection data exists.

Non-responsibilities:

- It does not run `Forecast::Engine`.
- It does not mutate records.
- It does not know about DOM structure.
- It does not perform authorization beyond consuming already-scoped family data.

The read model should reuse eager-loaded `Forecast::Workspace` data when possible to avoid N+1 queries over runs and months.

### JavaScript

The prototype currently has one large Stimulus controller. The complete feature should split concerns once behavior grows:

- `forecast_canvas_chart_controller.js`: D3 scales, axes, lines, zoom, hover, click, range, and metric rendering.
- `forecast_canvas_inspector_controller.js`: inspector mode transitions and field behavior.
- `forecast_canvas_drafts_controller.js`: draft lifecycle, form submission, response handling, and stale forecast state.

If keeping one controller is still simpler after extraction, it must remain internally organized around those same responsibilities.

D3 remains the right charting foundation because the feature needs custom interaction, layered event markers, zoom/pan, precise pointer hit-testing, and future drag behavior.

### Server Data Contract

The initial page payload contains:

- `source`: `latest_run` or `preview`.
- `currency`.
- `generated_at` and human label.
- `stale`: whether current assumptions changed after the latest completed run when this can be determined.
- `metrics`: key, label, format, and preferred axis behavior.
- `series`: id, label, color token, stack key, scenario ids, prototype/preview flag, and metric points.
- `events`: id, date, optional end date, label, kind, scenario id/name, effect kind, formatted amount, status, and color token.
- `stacks`: stack key, label, scenario names, feasibility, end values, low points, goal counts, and risk flags.
- `draft_options`: effect kinds, recurrence options, scenario targets, currencies, and form endpoints.
- `labels`: UI copy that must remain translatable.

Metric points contain:

- `date`.
- `value`.
- `formatted`.
- `delta_from_baseline` when a baseline point exists for the same date and metric.

### Persistence Contract

Canvas draft event creation posts to a Rails endpoint with:

- `name`.
- `forecast_scenario_id` or a request to create a new scenario.
- `effect`.
- `starts_on`.
- `ends_on`.
- `amount`.
- `currency`.
- `recurrence_rule` or equivalent existing recurrence fields.
- Additional effect-specific fields already supported by `ForecastEvent`.

The controller builds normal application records. It returns validation errors in a shape the inspector can render without a full page reload.

## Data And Consistency Rules

- `ForecastRun`, `ForecastMonth`, and `ForecastDay` remain immutable output records.
- `ForecastScenario`, `ForecastEvent`, `ForecastGoal`, budget assumptions, and liquidity settings remain editable input records.
- Canvas edits change inputs only.
- Forecast lines update only after a new forecast run completes.
- Historical run outputs remain tied to the assumptions snapshotted at run time.
- The canvas labels stale charts clearly after input edits.
- Preview data is never mixed with persisted run data.

## Error Handling

Server validation errors render inline in the inspector and preserve the draft marker.

Network or unexpected server errors keep the current chart visible and show a non-destructive alert in the inspector. The user should not lose local draft fields after a failed save.

If D3 rendering receives no usable points for the selected metric, the chart displays an empty metric state instead of throwing or drawing broken axes.

If every scenario line is toggled off, the chart shows a prompt to re-enable at least one line.

## Accessibility

- The chart has an accessible label and textual summary of the selected metric and range.
- Metric/range controls use buttons with `aria-pressed`.
- Scenario toggles use real checkboxes.
- Event and draft lists are keyboard reachable.
- The inspector updates an `aria-live` region after selection changes.
- Canvas-only interactions have equivalent controls in the inspector, especially for saving drafts and selecting events.
- Color is not the only differentiator: line style, labels, and selected-state text must convey meaning.

## Design System Rules

- Use functional design tokens from `sure-design-system.css`.
- Avoid raw Tailwind palette classes and hex literals in app views.
- Use `DS::Button`, `DS::Link`, `DS::Alert`, and existing form primitives where they fit.
- Use `icon` helper in ERB.
- Keep the app UI dense and operational.
- Do not add a marketing hero.
- Do not put cards inside cards.

## Testing Strategy

### Model Tests

Add tests for `Forecast::CanvasReadModel`:

- Preview payload when no completed run exists.
- Series payload from completed baseline and comparison runs.
- Events payload scoped to the current family.
- Delta calculation versus baseline.
- Stack summary metrics.
- Metric formatting for money and days.

### Controller Tests

Add tests for:

- `GET /forecast/canvas` renders the advanced route.
- Route requires authentication through existing app behavior.
- Payload is scoped to the signed-in family.
- Canvas draft event creation creates a `ForecastEvent` in the correct family.
- Invalid draft creation returns validation errors and does not create records.
- Scenario fork creation creates a `ForecastScenario` scoped to the family.

### JavaScript Checks

Run Biome on canvas controllers. Browser verification should cover:

- Desktop canvas renders nonblank SVG lines and axes.
- Mobile canvas renders controls without overlap.
- Metric switching changes axis and selected value formatting.
- Scenario toggle changes rendered line count.
- Event marker selection updates inspector.
- Timeline click opens draft mode.
- Draft save success updates event list or stale state.

## Rollout And Compatibility

The feature lands behind the separate `/forecast/canvas` route. It does not replace `/forecast`.

Existing users who ignore the advanced route should see only a small new entry point. Existing forecast run behavior, tabs, and generation flow must keep working.

The prototype route can continue during development, but the final state should have one canonical advanced canvas controller and route.

## Acceptance Criteria

The feature is complete when:

- `/forecast/canvas` is a namespaced, first-class forecast route.
- The route renders a polished advanced workspace using real forecast data when available.
- The route renders a clearly labeled preview state when no run data exists.
- Users can inspect points, events, scenario stacks, deltas, and forecast freshness.
- Users can create a forecast event from the canvas and persist it through existing models.
- Users can create or fork a scenario from the canvas.
- Users can regenerate forecasts through the existing run flow.
- `/forecast` links naturally to the advanced canvas without making it the default experience.
- The controller no longer carries chart payload construction.
- Tests cover read model behavior, controller behavior, and persistence.
- Browser verification confirms the chart and inspector work on desktop and mobile.
- The work is committed without staging unrelated budget-plan changes.

## Future Extensions

These are intentionally outside the first complete implementation but should be supported by the architecture:

- Drag event markers to reschedule assumptions.
- Brush-select a time range and apply a scenario to that window.
- Persist user-specific canvas layout preferences.
- Export canvas snapshots for reviews.
- Overlay actuals and reconciliation variance after forecast dates pass.
- Add Hermes-suggested scenario markers as a separate layer.
