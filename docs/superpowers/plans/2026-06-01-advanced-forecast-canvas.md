# Advanced Forecast Canvas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `/forecast/canvas` into a first-class advanced forecasting workspace where users can inspect forecast lines, compare scenarios, draft events on the timeline, fork scenarios, and regenerate through the existing forecast runner.

**Architecture:** Move canvas payload construction out of `ForecastsController` into `Forecast::CanvasReadModel`, render the page from `Forecast::CanvasController`, and persist graph-authored inputs through `Forecast::CanvasDraftsController`. The canvas reads immutable forecast outputs and writes normal forecast inputs; it never runs its own projection engine.

**Tech Stack:** Rails 7.2, Minitest, ERB, Hotwire/Turbo, Stimulus, D3, Biome, existing Sure design-system tokens and `DS::*` components.

---

## Worktree Safety

The branch currently contains unrelated budget-plan work. Do not stage it while implementing canvas work.

Use explicit paths for every `git add`. Before each commit, run:

```bash
git diff --cached --name-status
```

Expected: only files listed in the current task.

## File Structure

Create:

- `app/models/forecast/canvas_read_model.rb`: read-only serializer for chart payloads, events, stack summaries, and preview state.
- `app/controllers/forecast/canvas_controller.rb`: namespaced page controller for `/forecast/canvas`.
- `app/controllers/forecast/canvas_drafts_controller.rb`: JSON/Turbo write controller for canvas-authored events and scenario forks.
- `app/views/forecast/canvas/show.html.erb`: advanced canvas route view.
- `app/javascript/controllers/forecast_canvas_chart_controller.js`: D3 chart interaction and rendering.
- `test/models/forecast/canvas_read_model_test.rb`: read model coverage.
- `test/controllers/forecast/canvas_controller_test.rb`: route/page coverage.
- `test/controllers/forecast/canvas_drafts_controller_test.rb`: persistence coverage.

Modify:

- `config/routes.rb`: replace prototype route with namespaced `resource :canvas`.
- `app/controllers/forecasts_controller.rb`: remove prototype canvas action and private payload helpers.
- `app/controllers/forecast/base_controller.rb`: add canvas breadcrumb label/path support.
- `app/views/forecasts/show.html.erb`: add advanced canvas entry point.
- `app/views/forecasts/_empty_state.html.erb`: add advanced canvas entry where useful.
- `config/locales/views/forecasts/en.yml`: move/expand canvas copy.
- `test/controllers/forecasts_controller_test.rb`: remove prototype test and add integration-link assertion.

Delete:

- `app/views/forecasts/canvas.html.erb`
- `app/javascript/controllers/forecast_canvas_preview_controller.js`

---

### Task 1: Add `Forecast::CanvasReadModel`

**Files:**
- Create: `app/models/forecast/canvas_read_model.rb`
- Create: `test/models/forecast/canvas_read_model_test.rb`

- [ ] **Step 1: Write failing read-model tests**

Add tests that cover preview payload, completed-run series, event scoping, deltas, and stack summaries.

```ruby
require "test_helper"

class Forecast::CanvasReadModelTest < ActiveSupport::TestCase
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    @family.forecast_events.delete_all
    @family.forecast_scenarios.delete_all
  end

  test "returns preview payload when no completed projection exists" do
    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload

    assert_equal "preview", payload.fetch(:source)
    assert payload.fetch(:preview)
    assert payload.fetch(:series).size >= 2
    assert_includes payload.fetch(:metrics).map { |metric| metric.fetch(:key) }, "net_worth"
  end

  test "serializes completed run months into metric series" do
    build_run_group_with_series(family: @family, user: @user, months: 3)

    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload
    baseline = payload.fetch(:series).find { |series| series.fetch(:id) == "baseline" }

    assert_equal "latest_run", payload.fetch(:source)
    assert_equal false, payload.fetch(:preview)
    assert_equal 3, baseline.dig(:metrics, "net_worth").size
    assert_equal "$5,000.00", baseline.dig(:metrics, "net_worth").first.fetch(:formatted)
  end

  test "serializes only current family events" do
    mine = @family.forecast_events.create!(
      name: "Tuition",
      effect_type: "expense",
      behavior: "additive",
      amount: 1200,
      currency: @family.currency,
      starts_on: Date.current,
      status: "planned"
    )
    families(:empty).forecast_events.create!(
      name: "Foreign",
      effect_type: "income",
      behavior: "additive",
      amount: 1,
      currency: "USD",
      starts_on: Date.current,
      status: "planned"
    )

    payload = Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).payload
    labels = payload.fetch(:events).map { |event| event.fetch(:label) }

    assert_includes labels, mine.name
    assert_not_includes labels, "Foreign"
  end
end
```

- [ ] **Step 2: Run the model test and verify it fails**

Run:

```bash
bin/rails test test/models/forecast/canvas_read_model_test.rb
```

Expected: failure with `uninitialized constant Forecast::CanvasReadModel`.

- [ ] **Step 3: Implement the read model**

Create `app/models/forecast/canvas_read_model.rb` with this shape:

```ruby
module Forecast
  class CanvasReadModel
    COLORS = [
      "var(--color-blue-600)",
      "var(--color-green-600)",
      "var(--color-fuchsia-600)",
      "var(--color-yellow-600)",
      "var(--color-cyan-600)",
      "var(--color-indigo-600)"
    ].freeze

    METRICS = [
      [ "net_worth", :money ],
      [ "cash_balance", :money ],
      [ "liquid_balance", :money ],
      [ "portfolio_value", :money ],
      [ "debt_balance", :money ],
      [ "cash_runway_days", :days ]
    ].freeze

    def initialize(workspace)
      @workspace = workspace
      @family = workspace.family
    end

    def payload
      workspace.overview_data? ? latest_run_payload : preview_payload
    end

    private
      attr_reader :workspace, :family

      def latest_run_payload
        runs = workspace.comparison_runs.select { |run| run.status == "completed" && months_for(run).any? }
        series = runs.first(COLORS.size).each_with_index.map { |run, index| series_for_run(run, index) }

        {
          source: "latest_run",
          preview: false,
          currency: workspace.currency,
          generated_at: workspace.generated_at&.iso8601,
          generated_label: workspace.generated_at ? I18n.l(workspace.generated_at, format: :long) : nil,
          stale: stale?,
          metrics: metric_options,
          series: series,
          events: event_markers,
          stacks: stack_summaries(runs),
          draft_options: draft_options,
          labels: labels
        }
      end

      def preview_payload
        start_on = Date.current.beginning_of_month
        months = 37.times.map { |index| start_on + index.months }
        baseline = months.each_with_index.map do |date, index|
          {
            date: date.iso8601,
            net_worth: 92_000 + (index * 1_250),
            cash_balance: 18_000 + (index * 160),
            liquid_balance: 26_000 + (index * 220),
            portfolio_value: 48_000 + (index * 900),
            debt_balance: [ 31_000 - (index * 620), 4_500 ].max,
            cash_runway_days: 120 + (index * 2)
          }
        end

        {
          source: "preview",
          preview: true,
          currency: workspace.currency,
          generated_at: nil,
          generated_label: nil,
          stale: false,
          metrics: metric_options,
          series: [
            series_from_points("baseline", I18n.t("forecasts.comparison.baseline_label"), baseline, 0),
            series_from_points("preview_move", I18n.t("forecasts.canvas.preview_series.move"), preview_variant(baseline, -14_000), 1, preview: true),
            series_from_points("preview_drawdown", I18n.t("forecasts.canvas.preview_series.drawdown"), preview_variant(baseline, -22_000), 2, preview: true)
          ],
          events: preview_events(start_on),
          stacks: [],
          draft_options: draft_options,
          labels: labels
        }
      end
  end
end
```

Add private helpers in the same file:

- `months_for(run)` sorts already-loaded `forecast_months` in Ruby.
- `series_for_run(run, index)` maps `ForecastMonth` columns to points.
- `series_from_points(id, label, points, color_index, preview: false)` builds the metric hash.
- `event_markers` scopes through `family.forecast_events.includes(:forecast_scenario)`.
- `stack_summaries(runs)` computes end values and low points from each run's months.
- `draft_options` exposes `ForecastEvent::EFFECT_TYPES`, currencies, and active scenarios.
- `stale?` returns `false` for the first implementation.
- `format_value(value, format)` formats money with `Money.new(value, workspace.currency).format`.

- [ ] **Step 4: Run the model test and verify it passes**

Run:

```bash
bin/rails test test/models/forecast/canvas_read_model_test.rb
```

Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Commit Task 1**

```bash
git add app/models/forecast/canvas_read_model.rb test/models/forecast/canvas_read_model_test.rb
git diff --cached --name-status
git commit -m "Add forecast canvas read model"
```

---

### Task 2: Move `/forecast/canvas` To The Forecast Namespace

**Files:**
- Create: `app/controllers/forecast/canvas_controller.rb`
- Modify: `config/routes.rb`
- Modify: `app/controllers/forecast/base_controller.rb`
- Modify: `app/controllers/forecasts_controller.rb`
- Modify: `test/controllers/forecast/canvas_controller_test.rb`
- Modify: `test/controllers/forecasts_controller_test.rb`

- [ ] **Step 1: Write failing namespaced route/controller tests**

Create `test/controllers/forecast/canvas_controller_test.rb`:

```ruby
require "test_helper"

class Forecast::CanvasControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user
  end

  test "show renders the advanced canvas route" do
    get forecast_canvas_url

    assert_response :success
    assert_select "h1", text: I18n.t("forecasts.canvas.title")
    assert_select "[data-controller~='forecast-canvas-chart']"
    assert_select "[data-forecast-canvas-chart-payload-value]"
  end

  test "breadcrumbs are nested under forecast" do
    get forecast_canvas_url

    assert_response :success
    assert_equal [
      [ "Home", root_path ],
      [ "Forecast", forecast_path ],
      [ I18n.t("forecasts.canvas.title"), nil ]
    ], @controller.send(:breadcrumbs)
  end
end
```

- [ ] **Step 2: Run the new controller test and verify it fails**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_controller_test.rb
```

Expected: failure because `forecast_canvas_url` or `Forecast::CanvasController` does not exist.

- [ ] **Step 3: Replace the route**

In `config/routes.rb`, remove:

```ruby
get "forecast/canvas", to: "forecasts#canvas", as: :forecast_canvas_preview
```

Inside `namespace :forecast do`, add:

```ruby
resource :canvas, only: :show, controller: :canvas
```

- [ ] **Step 4: Add the controller**

Create `app/controllers/forecast/canvas_controller.rb`:

```ruby
module Forecast
  class CanvasController < BaseController
    def show
      @workspace = Forecast::Workspace.new(family: @family)
      @canvas_payload = Forecast::CanvasReadModel.new(@workspace).payload
    end
  end
end
```

- [ ] **Step 5: Add canvas breadcrumbs to the base controller**

In `Forecast::BaseController#forecast_collection_breadcrumb_label`, add:

```ruby
when "forecast/canvas" then t("forecasts.canvas.title")
```

In `#forecast_collection_breadcrumb_path`, add:

```ruby
when "forecast/canvas" then forecast_canvas_path
```

- [ ] **Step 6: Remove prototype controller code**

In `app/controllers/forecasts_controller.rb`, remove:

- `def canvas`
- all `CANVAS_PREVIEW_*` constants
- all private methods whose names start with `forecast_canvas`, `live_forecast_canvas`, `demo_forecast_canvas`, `canvas_series`, `derived_canvas`, `derive_canvas`, `canvas_metric`, `canvas_preview`, `canvas_events`, `months_for_canvas`, `canvas_stack_label`, and `canvas_format_value`

Keep `show` and `tab`.

- [ ] **Step 7: Update old prototype test**

In `test/controllers/forecasts_controller_test.rb`, delete `test "renders an isolated forecast canvas preview"`.

- [ ] **Step 8: Run route/controller tests**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_controller_test.rb test/controllers/forecasts_controller_test.rb
```

Expected: `0 failures, 0 errors`.

- [ ] **Step 9: Commit Task 2**

```bash
git add config/routes.rb app/controllers/forecast/canvas_controller.rb app/controllers/forecast/base_controller.rb app/controllers/forecasts_controller.rb test/controllers/forecast/canvas_controller_test.rb test/controllers/forecasts_controller_test.rb
git diff --cached --name-status
git commit -m "Route forecast canvas through forecast namespace"
```

---

### Task 3: Replace Prototype View With First-Class Canvas View

**Files:**
- Create: `app/views/forecast/canvas/show.html.erb`
- Delete: `app/views/forecasts/canvas.html.erb`
- Modify: `config/locales/views/forecasts/en.yml`

- [ ] **Step 1: Write view assertions**

Extend `Forecast::CanvasControllerTest#show renders the advanced canvas route` with:

```ruby
assert_select "a[href=?]", forecast_path, text: /Back to forecast/i
assert_select "[data-forecast-canvas-chart-target='chart']"
assert_select "[data-forecast-canvas-chart-target='inspector']"
assert_select "button[data-action*='forecast-canvas-chart#selectMetric']", minimum: 4
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_controller_test.rb
```

Expected: failure while the old view/controller target names remain.

- [ ] **Step 3: Create the namespaced view**

Move the prototype structure into `app/views/forecast/canvas/show.html.erb` and update controller names:

```erb
<% content_for :title, t("forecasts.canvas.title") %>

<div class="space-y-4 pb-6 lg:pb-12">
  <header class="flex flex-wrap items-start justify-between gap-3">
    <div class="space-y-1">
      <h1 class="text-primary text-2xl font-semibold"><%= t("forecasts.canvas.title") %></h1>
      <p class="text-secondary text-sm"><%= t("forecasts.canvas.description") %></p>
    </div>

    <div class="flex flex-wrap items-center gap-2">
      <%= render DS::Link.new(text: t("forecasts.canvas.back"), icon: "arrow-left", href: forecast_path, variant: "outline") %>
      <%= render DS::Button.new(text: t("forecasts.show.generate"), icon: "play", href: forecast_runs_path, disabled: @workspace.running?) %>
    </div>
  </header>

  <section class="overflow-hidden rounded-lg border border-primary bg-container"
           data-controller="forecast-canvas-chart"
           data-forecast-canvas-chart-payload-value="<%= @canvas_payload.to_json %>"
           aria-labelledby="forecast-canvas-heading">
    <div class="border-b border-primary p-3 sm:p-4">
      <div class="flex flex-col gap-3 xl:flex-row xl:items-center xl:justify-between">
        <div class="space-y-1">
          <h2 id="forecast-canvas-heading" class="text-primary text-base font-medium"><%= t("forecasts.canvas.chart_heading") %></h2>
          <p class="text-secondary text-xs" data-forecast-canvas-chart-target="sourceLabel"><%= t("forecasts.canvas.loading") %></p>
        </div>
      </div>
    </div>

    <div class="grid min-h-[38rem] lg:grid-cols-[minmax(0,1fr)_24rem]">
      <div class="relative border-b border-primary p-3 lg:border-b-0 lg:border-r sm:p-5">
        <div class="h-[34rem] min-h-96 privacy-sensitive" data-forecast-canvas-chart-target="chart"></div>
      </div>

      <aside class="flex min-h-full flex-col gap-4 p-4" data-forecast-canvas-chart-target="inspector"></aside>
    </div>
  </section>
</div>
```

Then port the metric/range/legend/event/selection markup from the prototype into the same structure using `forecast-canvas-chart` targets.

- [ ] **Step 4: Delete the old view**

Delete:

```bash
app/views/forecasts/canvas.html.erb
```

- [ ] **Step 5: Add/normalize locales**

Ensure `config/locales/views/forecasts/en.yml` contains:

```yaml
canvas:
  title: "Forecast canvas"
  description: "Advanced timeline workspace for comparing scenarios and editing forecast assumptions."
  back: "Back to forecast"
  chart_heading: "Timeline canvas"
  loading: "Loading forecast canvas..."
  preview_notice: "Preview data is shown because this family has no completed projection data yet."
  stale_notice: "Inputs changed after this forecast was generated."
```

Keep existing metric/range/event labels and add missing labels used by the read model.

- [ ] **Step 6: Run view tests**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_controller_test.rb
```

Expected: `0 failures, 0 errors`.

- [ ] **Step 7: Commit Task 3**

```bash
git add app/views/forecast/canvas/show.html.erb app/views/forecasts/canvas.html.erb config/locales/views/forecasts/en.yml test/controllers/forecast/canvas_controller_test.rb
git diff --cached --name-status
git commit -m "Add advanced forecast canvas view"
```

---

### Task 4: Refactor The Canvas Stimulus Controller

**Files:**
- Create: `app/javascript/controllers/forecast_canvas_chart_controller.js`
- Delete: `app/javascript/controllers/forecast_canvas_preview_controller.js`

- [ ] **Step 1: Copy and rename the controller**

Start from the prototype controller. Rename all Stimulus identifiers from preview to chart:

```js
export default class extends Controller {
  static targets = [
    "chart",
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
}
```

- [ ] **Step 2: Add payload compatibility for the read model**

Update normalization to accept:

```js
const points = series.metrics?.[metric] || [];
const eventKey = event.id || `${event.label}-${event.date}`;
const isPreview = series.preview || series.prototype;
```

- [ ] **Step 3: Add empty and all-lines-off states**

In `#renderChart`, before drawing axes:

```js
if (activeSeries.length === 0) {
  this.#renderEmptyChart(svg, width, height, this.payload.labels?.line_empty);
  return;
}

if (allPoints.length < 2) {
  this.#renderEmptyChart(svg, width, height, this.payload.labels?.metric_empty);
  return;
}
```

Add:

```js
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
```

- [ ] **Step 4: Delete the preview controller**

Delete:

```bash
app/javascript/controllers/forecast_canvas_preview_controller.js
```

- [ ] **Step 5: Run Biome**

Run:

```bash
npx --yes @biomejs/biome@1.9.3 lint app/javascript/controllers/forecast_canvas_chart_controller.js
```

Expected: `No fixes applied`.

- [ ] **Step 6: Run controller test**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_controller_test.rb
```

Expected: `0 failures, 0 errors`.

- [ ] **Step 7: Commit Task 4**

```bash
git add app/javascript/controllers/forecast_canvas_chart_controller.js app/javascript/controllers/forecast_canvas_preview_controller.js app/views/forecast/canvas/show.html.erb
git diff --cached --name-status
git commit -m "Refine forecast canvas chart controller"
```

---

### Task 5: Add Canvas Draft Event Persistence

**Files:**
- Create: `app/controllers/forecast/canvas_drafts_controller.rb`
- Create: `test/controllers/forecast/canvas_drafts_controller_test.rb`
- Modify: `config/routes.rb`
- Modify: `app/models/forecast/canvas_read_model.rb`

- [ ] **Step 1: Write failing draft tests**

Create `test/controllers/forecast/canvas_drafts_controller_test.rb`:

```ruby
require "test_helper"

class Forecast::CanvasDraftsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_events.delete_all
    @scenario = @family.forecast_scenarios.create!(name: "Move", status: "active", approval_status: "manual")
    sign_in @user
  end

  test "create persists a canvas-authored forecast event" do
    assert_difference "@family.forecast_events.count", 1 do
      post forecast_canvas_drafts_path(format: :json), params: {
        forecast_event: {
          name: "Relocation cost",
          effect_type: "expense",
          amount: "5000",
          currency: @family.currency,
          starts_on: Date.current.to_s,
          status: "planned",
          probability_weight: "1.0",
          forecast_scenario_id: @scenario.id
        }
      }
    end

    assert_response :created
    event = @family.forecast_events.order(:created_at).last
    assert_equal "Relocation cost", event.name
    assert_equal @scenario.id, event.forecast_scenario_id
    assert_equal "additive", event.behavior
  end

  test "create rejects invalid draft without persisting" do
    assert_no_difference "@family.forecast_events.count" do
      post forecast_canvas_drafts_path(format: :json), params: {
        forecast_event: {
          name: "",
          effect_type: "expense",
          amount: "",
          currency: @family.currency,
          starts_on: Date.current.to_s,
          status: "planned"
        }
      }
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["errors"].present?
  end

  test "create rejects a foreign scenario id" do
    foreign = families(:empty).forecast_scenarios.create!(name: "Foreign", status: "active", approval_status: "manual")

    assert_raises ActiveRecord::RecordNotFound do
      post forecast_canvas_drafts_path(format: :json), params: {
        forecast_event: {
          name: "Invalid",
          effect_type: "income",
          amount: "10",
          currency: @family.currency,
          starts_on: Date.current.to_s,
          status: "planned",
          forecast_scenario_id: foreign.id
        }
      }
    end
  end
end
```

- [ ] **Step 2: Run the draft test and verify it fails**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_drafts_controller_test.rb
```

Expected: failure because the route/controller does not exist.

- [ ] **Step 3: Add draft routes**

Inside `namespace :forecast do` in `config/routes.rb`:

```ruby
resources :canvas_drafts, path: "canvas/drafts", only: :create
post "canvas/forks", to: "canvas_drafts#fork", as: :canvas_forks
```

- [ ] **Step 4: Implement draft create**

Create `app/controllers/forecast/canvas_drafts_controller.rb`:

```ruby
module Forecast
  class CanvasDraftsController < BaseController
    def create
      @event = @family.forecast_events.new(event_params)
      @event.behavior = "additive"
      @event.status = "planned" if @event.status.blank?
      @event.currency = @family.currency if @event.currency.blank?
      @event.probability_weight = 1.0 if @event.probability_weight.blank?

      if @event.save
        render json: {
          event: Forecast::CanvasReadModel.new(Forecast::Workspace.new(family: @family)).event_marker(@event),
          stale: true,
          message: I18n.t("forecasts.canvas.drafts.created")
        }, status: :created
      else
        render json: { errors: @event.errors.to_hash(true) }, status: :unprocessable_entity
      end
    end

    private
      def event_params
        permitted = params.require(:forecast_event).permit(
          :name, :description, :effect_type, :amount, :currency,
          :starts_on, :ends_on, :status, :probability_weight,
          :forecast_scenario_id, :account_id, :destination_account_id, :category_id,
          :recurring, recurrence_rule: %i[frequency interval day_of_month],
          source_metadata: %i[destination_amount destination_currency]
        )

        if permitted[:forecast_scenario_id].present?
          permitted[:forecast_scenario_id] = @family.forecast_scenarios.find(permitted[:forecast_scenario_id]).id
        end

        normalize_recurrence(permitted)
        permitted
      end

      def normalize_recurrence(permitted)
        recurring = ActiveModel::Type::Boolean.new.cast(permitted.delete(:recurring))
        rule = permitted[:recurrence_rule]

        unless recurring && rule.present?
          permitted[:recurrence_rule] = {}
          return
        end

        permitted[:recurrence_rule] = {
          "frequency" => rule[:frequency].presence || "monthly",
          "interval" => rule[:interval].presence&.to_i || 1
        }
        permitted[:recurrence_rule]["day_of_month"] = rule[:day_of_month].to_i if rule[:day_of_month].present?
      end
  end
end
```

Expose `event_marker(event)` as a public method on `Forecast::CanvasReadModel`; have the private `event_markers` method call that same public method for each persisted event.

- [ ] **Step 5: Run draft tests**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_drafts_controller_test.rb
```

Expected: `0 failures, 0 errors`.

- [ ] **Step 6: Commit Task 5**

```bash
git add config/routes.rb app/controllers/forecast/canvas_drafts_controller.rb app/models/forecast/canvas_read_model.rb test/controllers/forecast/canvas_drafts_controller_test.rb
git diff --cached --name-status
git commit -m "Add forecast canvas draft persistence"
```

---

### Task 6: Add Scenario Fork Persistence

**Files:**
- Modify: `app/controllers/forecast/canvas_drafts_controller.rb`
- Modify: `test/controllers/forecast/canvas_drafts_controller_test.rb`
- Modify: `app/models/forecast/canvas_read_model.rb`

- [ ] **Step 1: Write failing fork tests**

Append to `Forecast::CanvasDraftsControllerTest`:

```ruby
test "fork duplicates an existing scenario for the canvas" do
  @scenario.forecast_events.create!(
    family: @family,
    name: "Rent increase",
    effect_type: "expense",
    behavior: "additive",
    amount: 300,
    currency: @family.currency,
    starts_on: Date.current,
    status: "planned"
  )

  assert_difference "@family.forecast_scenarios.count", 1 do
    post forecast_canvas_forks_path(format: :json), params: {
      source_scenario_id: @scenario.id,
      name: "Move fork"
    }
  end

  assert_response :created
  copy = @family.forecast_scenarios.order(:created_at).last
  assert_equal "Move fork", copy.name
  assert_equal @scenario.id, copy.parent_scenario_id
end

test "fork creates a new blank scenario from baseline" do
  assert_difference "@family.forecast_scenarios.count", 1 do
    post forecast_canvas_forks_path(format: :json), params: {
      source: "baseline",
      name: "Baseline fork"
    }
  end

  assert_response :created
  assert_equal "Baseline fork", @family.forecast_scenarios.order(:created_at).last.name
end
```

- [ ] **Step 2: Run tests and verify fork tests fail**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_drafts_controller_test.rb
```

Expected: failure because `fork` is not implemented.

- [ ] **Step 3: Implement fork action**

Add to `Forecast::CanvasDraftsController`:

```ruby
def fork
  scenario =
    if params[:source_scenario_id].present?
      source = @family.forecast_scenarios.find(params[:source_scenario_id])
      source.duplicate_for_family!(family: @family, user: Current.user, name: params[:name])
    else
      @family.forecast_scenarios.create!(
        name: params[:name].presence || I18n.t("forecasts.canvas.forks.default_name"),
        status: "active",
        approval_status: "manual",
        starts_on: params[:starts_on].presence,
        created_by_user: Current.user
      )
    end

  render json: {
    scenario: {
      id: scenario.id,
      name: scenario.name,
      status: scenario.status,
      parent_scenario_id: scenario.parent_scenario_id
    },
    stale: true,
    message: I18n.t("forecasts.canvas.forks.created")
  }, status: :created
rescue ActiveRecord::RecordInvalid => e
  render json: { errors: e.record.errors.to_hash(true) }, status: :unprocessable_entity
end
```

- [ ] **Step 4: Run fork tests**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_drafts_controller_test.rb
```

Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Commit Task 6**

```bash
git add app/controllers/forecast/canvas_drafts_controller.rb test/controllers/forecast/canvas_drafts_controller_test.rb app/models/forecast/canvas_read_model.rb config/locales/views/forecasts/en.yml
git diff --cached --name-status
git commit -m "Add forecast canvas scenario forks"
```

---

### Task 7: Wire Inspector Draft UI

**Files:**
- Modify: `app/views/forecast/canvas/show.html.erb`
- Modify: `app/javascript/controllers/forecast_canvas_chart_controller.js`
- Modify: `config/locales/views/forecasts/en.yml`
- Modify: `test/controllers/forecast/canvas_controller_test.rb`

- [ ] **Step 1: Add view assertions for draft form shell**

In `Forecast::CanvasControllerTest`, add:

```ruby
assert_select "template[data-forecast-canvas-chart-target='draftTemplate']"
assert_select "form[data-forecast-canvas-chart-target='draftForm']"
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_controller_test.rb
```

Expected: failure because the template/form shell is not present.

- [ ] **Step 3: Add a hidden draft template**

In the canvas view, add a `<template>` target with fields:

```erb
<template data-forecast-canvas-chart-target="draftTemplate">
  <form class="space-y-3" data-forecast-canvas-chart-target="draftForm" data-action="submit->forecast-canvas-chart#saveDraft">
    <input type="hidden" name="forecast_event[starts_on]" data-forecast-canvas-chart-target="draftStartsOn">
    <div class="space-y-1">
      <label class="text-primary text-sm font-medium" for="canvas-draft-name"><%= t("forecasts.canvas.drafts.name") %></label>
      <input id="canvas-draft-name" class="form-field__input" name="forecast_event[name]" type="text" required>
    </div>
    <div class="space-y-1">
      <label class="text-primary text-sm font-medium" for="canvas-draft-effect"><%= t("forecasts.canvas.drafts.effect") %></label>
      <select id="canvas-draft-effect" class="form-field__input" name="forecast_event[effect_type]">
        <% @canvas_payload.dig(:draft_options, :effect_types).each do |effect_type| %>
          <option value="<%= effect_type %>"><%= t("forecasts.events.effect_types.#{effect_type}", default: effect_type.humanize) %></option>
        <% end %>
      </select>
    </div>
    <div class="space-y-1">
      <label class="text-primary text-sm font-medium" for="canvas-draft-amount"><%= t("forecasts.canvas.drafts.amount") %></label>
      <input id="canvas-draft-amount" class="form-field__input" name="forecast_event[amount]" type="number" step="0.01">
    </div>
    <button type="submit" class="btn btn--primary"><%= t("forecasts.canvas.drafts.save") %></button>
  </form>
</template>
```

Use existing form classes from local views instead of introducing new raw CSS if these class names differ.

- [ ] **Step 4: Implement `saveDraft` in Stimulus**

In the controller:

```js
async saveDraft(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const response = await fetch(this.payload.draft_options.create_event_url, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "",
    },
    body: new FormData(form),
  });

  const body = await response.json();
  if (!response.ok) {
    this.#renderDraftErrors(body.errors || {});
    return;
  }

  this.payload.events.push({
    ...body.event,
    dateObject: parseDate(body.event.date),
  });
  this.payload.stale = true;
  this.#renderEvents();
  this.#updateEvents();
  this.#selectEvent(this.payload.events[this.payload.events.length - 1]);
}
```

- [ ] **Step 5: Run tests and lint**

Run:

```bash
bin/rails test test/controllers/forecast/canvas_controller_test.rb test/controllers/forecast/canvas_drafts_controller_test.rb
npx --yes @biomejs/biome@1.9.3 lint app/javascript/controllers/forecast_canvas_chart_controller.js
```

Expected: Rails tests pass and Biome reports no fixes.

- [ ] **Step 6: Commit Task 7**

```bash
git add app/views/forecast/canvas/show.html.erb app/javascript/controllers/forecast_canvas_chart_controller.js config/locales/views/forecasts/en.yml test/controllers/forecast/canvas_controller_test.rb
git diff --cached --name-status
git commit -m "Wire forecast canvas draft inspector"
```

---

### Task 8: Integrate The Advanced Canvas Into `/forecast`

**Files:**
- Modify: `app/views/forecasts/show.html.erb`
- Modify: `app/views/forecasts/_empty_state.html.erb`
- Modify: `config/locales/views/forecasts/en.yml`
- Modify: `test/controllers/forecasts_controller_test.rb`

- [ ] **Step 1: Add failing link assertions**

In `ForecastsControllerTest`, add:

```ruby
test "renders an advanced canvas link for completed forecasts" do
  build_completed_run_group(family: @family, user: @user, runs: 1)

  get forecast_url

  assert_response :success
  assert_select "a[href=?]", forecast_canvas_path, text: /Advanced canvas/i
end

test "renders an advanced canvas link in the empty state" do
  get forecast_url

  assert_response :success
  assert_select "a[href=?]", forecast_canvas_path, text: /Advanced canvas/i
end
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
bin/rails test test/controllers/forecasts_controller_test.rb -n "/advanced canvas/"
```

Expected: failures because links are missing.

- [ ] **Step 3: Add links using DS components**

In `app/views/forecasts/show.html.erb`, add a secondary link in the header:

```erb
<%= render DS::Link.new(
  text: t("forecasts.canvas.open"),
  icon: "line-chart",
  href: forecast_canvas_path,
  variant: "outline"
) %>
```

In `_empty_state.html.erb`, add the same link as a secondary action near the guided primary action.

- [ ] **Step 4: Run forecast controller tests**

Run:

```bash
bin/rails test test/controllers/forecasts_controller_test.rb -n "/advanced canvas/"
```

Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Commit Task 8**

```bash
git add app/views/forecasts/show.html.erb app/views/forecasts/_empty_state.html.erb config/locales/views/forecasts/en.yml test/controllers/forecasts_controller_test.rb
git diff --cached --name-status
git commit -m "Link advanced canvas from forecast workspace"
```

---

### Task 9: Browser Verification And Final Cleanup

**Files:**
- Modify only canvas files identified by the failed verification command.

- [ ] **Step 1: Run focused Rails tests**

Run:

```bash
bin/rails test test/models/forecast/canvas_read_model_test.rb test/controllers/forecast/canvas_controller_test.rb test/controllers/forecast/canvas_drafts_controller_test.rb test/controllers/forecasts_controller_test.rb
```

Expected: `0 failures, 0 errors`.

- [ ] **Step 2: Run Ruby syntax checks**

Run:

```bash
ruby -c app/models/forecast/canvas_read_model.rb
ruby -c app/controllers/forecast/canvas_controller.rb
ruby -c app/controllers/forecast/canvas_drafts_controller.rb
ruby -c app/controllers/forecasts_controller.rb
ruby -c config/routes.rb
```

Expected: every command prints `Syntax OK`.

- [ ] **Step 3: Run JS lint**

Run:

```bash
npx --yes @biomejs/biome@1.9.3 lint app/javascript/controllers/forecast_canvas_chart_controller.js
```

Expected: `No fixes applied`.

- [ ] **Step 4: Start a local Rails server for browser verification**

Use the project's normal local DB environment. If port 3000 is occupied, use 3001:

```bash
bin/rails server -p 3001
```

- [ ] **Step 5: Verify desktop render with Playwright**

Open `/forecast/canvas`, sign in with a test user, and evaluate:

```js
() => ({
  path: location.pathname,
  title: document.title,
  svgCount: document.querySelectorAll("[data-forecast-canvas-chart-target=chart] svg").length,
  lineCount: document.querySelectorAll("path.forecast-line").length,
  metricButtons: document.querySelectorAll("[data-action*='forecast-canvas-chart#selectMetric']").length
})
```

Expected:

```json
{
  "path": "/forecast/canvas",
  "title": "Forecast canvas",
  "svgCount": 1,
  "lineCount": 2,
  "metricButtons": 6
}
```

Line count may be higher when real completed comparison runs exist.

- [ ] **Step 6: Verify mobile render with Playwright**

Resize to a mobile viewport and verify:

```js
() => ({
  width: innerWidth,
  hasHorizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
  chartExists: !!document.querySelector("[data-forecast-canvas-chart-target=chart] svg")
})
```

Expected: `hasHorizontalOverflow` is `false` and `chartExists` is `true`.

- [ ] **Step 7: Stop the local Rails server**

Stop the process started in Step 4. Verify the port is closed:

```bash
lsof -i :3001 -sTCP:LISTEN -n -P
```

Expected: no output.

- [ ] **Step 8: Commit any verification fixes**

If verification required fixes:

```bash
git add <explicit canvas files only>
git diff --cached --name-status
git commit -m "Stabilize advanced forecast canvas"
```

- [ ] **Step 9: Push the branch**

```bash
git push origin forecasting-foundation
```

Expected: push succeeds.
