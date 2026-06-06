require "test_helper"
require "inertia_rails/minitest"

# THROWAWAY viability spike coverage (Forecast V2 / slice A2). Proves the
# authenticated /forecast_v2_spike route renders an Inertia page with typed,
# read-model-shaped props that never touch the V1 Forecast::Workspace / engine /
# run-group tables. Delete with the ForecastV2SpikeController and its Inertia
# page when the spike is folded into Phase 2 or removed.
class ForecastV2SpikeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  test "redirects to sign in when signed out" do
    get forecast_v2_spike_path

    assert_redirected_to new_session_url
  end

  test "renders the Forecast/Spike Inertia component for an authenticated user" do
    sign_in @user
    get forecast_v2_spike_path

    assert_response :success
    assert_inertia_component "Forecast/Spike"
  end

  test "renders through the dedicated forecast_inertia layout with Vite tags and privacy/dark-mode checks" do
    sign_in @user
    get forecast_v2_spike_path

    assert_response :success

    # Dedicated forecast_inertia layout reuses shared/_head, so the auth/privacy
    # chrome the blueprint requires is preserved. (csrf_meta_tags emits nothing
    # in the test env because allow_forgery_protection is off, so we assert on
    # the always-present Tailwind stylesheet + viewport meta from shared/_head.)
    assert_select "link[rel=stylesheet][href*=tailwind]", { minimum: 1 },
      "expected the Tailwind stylesheet from shared/_head"
    assert_select "meta[name=viewport]", { minimum: 1 }, "expected the viewport meta from shared/_head"
    assert_match "localStorage.getItem('privacyMode')", response.body,
      "expected privacy-mode no-flash check in the rendered layout"
    assert_match "localStorage.theme === 'dark'", response.body,
      "expected dark-mode no-flash check in the rendered layout"

    # Vite asset tag (compiled entrypoint resolved via the Vite manifest in the
    # test environment; the dev-only client + react-refresh tags are no-ops here).
    assert_select "script[type=module][src*=vite-test]", { minimum: 1 },
      "expected a Vite-built module script tag in the rendered layout"

    # The dedicated layout deliberately omits the full application shell: no left
    # app nav, no right-side chat container that would squeeze the workspace.
    assert_select "#chat-container", { count: 0 },
      "expected no right-side chat container in the dedicated forecast layout"
  end

  test "serializes the initial Inertia page as a JSON script element the client can read" do
    sign_in @user
    get forecast_v2_spike_path

    assert_response :success

    # The installed @inertiajs/core client reads the initial page ONLY from a
    # `<script type="application/json" data-page="app">` element
    # (getInitialPageFromDOM). With the gem's default `data-page`-attribute
    # rendering the React root silently fails to hydrate, so this guards the
    # server/client contract the spike system test (A7) depends on.
    assert_select "script[type='application/json'][data-page='app']", { count: 1 },
      "expected the initial Inertia page serialized as a JSON script element"
    assert_select "div#app", { count: 1 }, "expected the Inertia mount div"
    assert_select "div#app[data-page]", { count: 0 },
      "initial page must live in the script element, not a data-page attribute"

    page_node = css_select("script[type='application/json'][data-page='app']").first
    page_payload = JSON.parse(page_node.text)
    assert_equal "Forecast/Spike", page_payload["component"],
      "expected the script payload to name the Forecast/Spike component"
    assert page_payload.dig("props", "plan", "label").present?,
      "expected the script payload to carry the typed plan label prop"
  end

  test "exposes only typed read-model-shaped props" do
    sign_in @user
    get forecast_v2_spike_path

    assert_response :success

    %i[plan currentPeriodKey periodKeys series metrics privacy freshness].each do |key|
      assert inertia.props.key?(key), "expected Inertia props to include #{key}"
    end
  end

  test "plan prop carries a label and currency context" do
    sign_in @user
    get forecast_v2_spike_path

    plan = inertia.props[:plan]
    assert plan[:label].present?, "expected plan.label to be present"
    assert plan[:currency].present?, "expected plan.currency to be present"
  end

  test "period props are ordered and consistent with the metric series" do
    sign_in @user
    get forecast_v2_spike_path

    period_keys = inertia.props[:periodKeys]
    series = inertia.props[:series]

    assert period_keys.is_a?(Array)
    assert_equal period_keys.sort, period_keys, "expected period keys to be chronologically ordered"
    assert_includes period_keys, inertia.props[:currentPeriodKey]
    assert_equal period_keys, series.map { |point| point[:periodKey] },
      "expected one series point per period key, in order"
  end

  test "each series point exposes decimal-string net worth and cash metrics" do
    sign_in @user
    get forecast_v2_spike_path

    series = inertia.props[:series]
    assert series.any?

    series.each do |point|
      assert point.key?(:netWorth), "expected series point to include netWorth"
      assert point.key?(:cash), "expected series point to include cash"
      assert_kind_of String, point[:netWorth]
      assert_kind_of String, point[:cash]
      assert_match(/\A-?\d+\.\d{2}\z/, point[:netWorth])
      assert_match(/\A-?\d+\.\d{2}\z/, point[:cash])
    end
  end

  test "privacy and freshness props carry typed state" do
    sign_in @user
    get forecast_v2_spike_path

    assert_includes [ true, false ], inertia.props[:privacy][:enabled]
    assert_includes %w[fresh stale recomputing], inertia.props[:freshness][:state]
  end

  test "does not read or mutate any V1 forecast workspace or run groups" do
    sign_in @user

    Forecast::Workspace.expects(:new).never
    assert_no_difference -> { @user.family.forecast_run_groups.count } do
      get forecast_v2_spike_path
    end

    assert_response :success
  end
end
