require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get forecast_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "renders for users with preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get forecast_url

    assert_response :success
    assert_select "h1", text: /Forecast/i
  end
end
