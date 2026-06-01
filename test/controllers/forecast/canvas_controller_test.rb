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
    assert_select "a[href=?]", forecast_path, text: /Back to forecast/i
    assert_select "[data-forecast-canvas-chart-target='chart']"
    assert_select "[data-forecast-canvas-chart-target='inspector']"
    assert_select "[data-forecast-canvas-chart-target='detailPanel']"
    assert_select "[data-forecast-canvas-chart-target='viewportLabel']"
    assert_select "button[data-action*='forecast-canvas-chart#selectMetric']", minimum: 4
    assert_select "button[data-action*='forecast-canvas-chart#zoomIn']"
    assert_select "button[data-action*='forecast-canvas-chart#zoomOut']"
    assert_select "button[data-action*='forecast-canvas-chart#resetZoom']"
    assert_select "template[data-forecast-canvas-chart-target='draftTemplate']"
    assert_select "form[data-forecast-canvas-chart-target='draftForm']"
    assert_select "form[data-controller~='forecast-event-form']"
    assert_select "select[name='forecast_event[scenario_target]']"
    assert_select "input[name='forecast_event[new_scenario_name]']"
    assert_select "select[name='forecast_event[category_id]']"
    assert_select "select[name='forecast_event[account_id]']"
    assert_select "select[name='forecast_event[destination_account_id]']"
    assert_select "input[name='forecast_event[recurring]']"
    assert_select "select[name='forecast_event[recurrence_rule][frequency]']"
    assert_select "input[name='forecast_event[recurrence_rule][interval]']"
    assert_select "input[name='forecast_event[ends_on]']"
    assert_select "input[name='forecast_event[probability_weight]']"
    assert_select "textarea[name='forecast_event[description]']"
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

  test "chart overlay selects nearby event markers before creating drafts" do
    controller_source = Rails.root.join("app/javascript/controllers/forecast_canvas_chart_controller.js").read

    assert_includes controller_source, '.on("click", (event) => this.#handleOverlayClick(event))'
    assert_includes controller_source, "#nearestEventToPointer(event)"
    assert_includes controller_source, "this.#selectEvent(nearestEvent)"
    assert_includes controller_source, "this.#addDraftMarker(event)"
  end

  test "chart exposes explicit timeline viewport controls" do
    controller_source = Rails.root.join("app/javascript/controllers/forecast_canvas_chart_controller.js").read

    assert_includes controller_source, '"viewportLabel"'
    assert_includes controller_source, "zoomIn()"
    assert_includes controller_source, "zoomOut()"
    assert_includes controller_source, "resetZoom()"
    assert_includes controller_source, "#zoomBy(factor)"
    assert_includes controller_source, "#renderViewportLabel()"
  end

  test "chart keeps selected lines and event markers visually synchronized" do
    controller_source = Rails.root.join("app/javascript/controllers/forecast_canvas_chart_controller.js").read

    assert_includes controller_source, "this.selectedSeriesId"
    assert_includes controller_source, "this.selectedEventKey"
    assert_includes controller_source, "data-forecast-canvas-series-id"
    assert_includes controller_source, "data-forecast-canvas-event-key"
    assert_includes controller_source, "#syncSelectionStyles()"
    assert_includes controller_source, "#isSelectedSeries(series)"
    assert_includes controller_source, "#isSelectedEvent(event)"
  end

  test "chart initializes advanced route state from URL params" do
    controller_source = Rails.root.join("app/javascript/controllers/forecast_canvas_chart_controller.js").read

    assert_includes controller_source, "#stateFromUrl()"
    assert_includes controller_source, "searchParams.get(\"metric\")"
    assert_includes controller_source, "searchParams.get(\"range\")"
    assert_includes controller_source, "searchParams.get(\"series\")"
    assert_includes controller_source, "searchParams.get(\"event\")"
    assert_includes controller_source, "#applyInitialSelectionFromUrl()"
  end

  test "chart persists advanced route state to the URL" do
    controller_source = Rails.root.join("app/javascript/controllers/forecast_canvas_chart_controller.js").read

    assert_includes controller_source, "#syncUrlState()"
    assert_includes controller_source, "window.history.replaceState"
    assert_includes controller_source, "searchParams.set(\"metric\", this.selectedMetric)"
    assert_includes controller_source, "searchParams.set(\"range\", this.selectedRange)"
    assert_includes controller_source, "searchParams.set(\"series\", this.selectedSeriesId)"
    assert_includes controller_source, "searchParams.set(\"event\", this.selectedEventKey)"
  end

  test "chart event rail follows the current timeline viewport" do
    controller_source = Rails.root.join("app/javascript/controllers/forecast_canvas_chart_controller.js").read

    assert_includes controller_source, "#renderEvents(domain)"
    assert_includes controller_source, "#visibleEventsForDomain(domain"
    assert_includes controller_source, "EVENT_LIST_LIMIT"
    assert_includes controller_source, "labels.event_more_visible"
    assert_includes controller_source, "labels.event_outside_visible"
    assert_includes controller_source, "#eventCountText("
  end
end
