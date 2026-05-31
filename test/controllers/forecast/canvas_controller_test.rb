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
    assert_select "button[data-action*='forecast-canvas-chart#selectMetric']", minimum: 4
    assert_select "template[data-forecast-canvas-chart-target='draftTemplate']"
    assert_select "form[data-forecast-canvas-chart-target='draftForm']"
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
