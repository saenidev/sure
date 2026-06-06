require "test_helper"

class LayoutAccessibilityTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "application layout renders skip-link pointing at #main and a <main> with id=\"main\"" do
    get root_path
    assert_response :ok

    skip_text = I18n.t("layouts.application.skip_to_main")

    assert_select "a[href=\"#main\"]", text: skip_text
    assert_select "main#main"
  end

  test "application layout allows Turbo hover prefetch" do
    get root_path
    assert_response :ok

    assert_select "meta[name='turbo-prefetch']", count: 0
  end

  test "authenticated application layout preloads route code and route shells" do
    get root_path
    assert_response :ok

    assert_includes response.body, 'rel="modulepreload" href="/assets/controllers/'
    assert_includes response.body, 'rel="modulepreload" href="/assets/d3'
    assert_includes response.body, "route-preloader"
    assert_includes response.body, "data-route-preloader-paths-value"
  end

  test "application layout sidebar renders a nav link to the Forecast V2 workspace" do
    get root_path
    assert_response :ok

    forecast_v2_label = I18n.t("layouts.application.nav.forecast_v2")

    assert_select "a[href=\"#{forecast_v2_path}\"]" do
      assert_select "p", text: forecast_v2_label
    end
  end

  test "settings layout renders skip-link pointing at #main and a <main> with id=\"main\"" do
    get settings_profile_path
    assert_response :ok

    skip_text = I18n.t("layouts.application.skip_to_main")

    assert_select "a[href=\"#main\"]", text: skip_text
    assert_select "main#main"
  end
end
