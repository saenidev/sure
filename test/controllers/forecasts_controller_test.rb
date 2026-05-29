require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "renders for users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get forecast_url

    assert_response :success
    assert_select "h1", text: /Forecast/i
  end

  test "renders for users with preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get forecast_url

    assert_response :success
    assert_select "h1", text: /Forecast/i
  end

  test "renders a sidebar nav link to the forecast page" do
    get forecast_url

    assert_response :success
    assert_select "a[href=?]", forecast_path
  end
end
