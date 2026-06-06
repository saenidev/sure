require "test_helper"
require "inertia_rails/minitest"

# Slice C1: prove /forecast renders V2 only when the V2 feature check passes, and
# otherwise keeps the unchanged V1 Forecast::Workspace path so V1 is not broken
# for everyone else.
#
# Spec: "V1 Coexistence", "Feature Flags And Release Control", Stage C feature
# gate. The gate is a feature CHECK at the canonical /forecast URL, not a separate
# mounted route, so the same URL flips between V1 and V2.
class ForecastsControllerV2GateTest < ActionDispatch::IntegrationTest
  include ForecastRunGroupTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.forecast_run_groups.delete_all
    @family.forecast_events.delete_all
    @family.forecast_scenarios.delete_all
    @family.forecast_goals.delete_all
    sign_in @user
  end

  # --- global switch off (default): everyone gets V1 -------------------------

  test "renders the V1 Forecast::Workspace surface when V2 is globally disabled" do
    with_v2_global(false) do
      get forecast_url

      assert_response :success
      # V1 ERB surface (server-rendered heading), not an Inertia page.
      assert_select "h1", text: /Forecast/i
      assert_select "div#app", { count: 0 }, "expected no Inertia mount on the V1 surface"
    end
  end

  test "V1 stays default even for a preview-opted user when V2 is globally disabled" do
    enable_user_preview(@user)

    with_v2_global(false) do
      get forecast_url

      assert_response :success
      assert_select "h1", text: /Forecast/i
      assert_select "div#app", { count: 0 }
    end
  end

  # --- global switch on, but family/user not opted in: still V1 -------------

  test "renders V1 when V2 is globally enabled but the family/user are not opted in" do
    with_v2_global(true) do
      with_v2_family_ids([]) do
        get forecast_url

        assert_response :success
        assert_select "h1", text: /Forecast/i
        assert_select "div#app", { count: 0 }
      end
    end
  end

  # --- V2 renders when the feature check passes ------------------------------

  test "renders the V2 Inertia surface when the family is allowlisted" do
    with_v2_global(true) do
      with_v2_family_ids([ @family.id.to_s ]) do
        get forecast_url

        assert_response :success
        assert_inertia_component "Forecast/Workspace"
        assert_select "div#app", { count: 1 }, "expected the Inertia mount on the V2 surface"
      end
    end
  end

  test "renders the V2 Inertia surface when the user has the preview flag" do
    enable_user_preview(@user)

    with_v2_global(true) do
      with_v2_family_ids([]) do
        get forecast_url

        assert_response :success
        assert_inertia_component "Forecast/Workspace"
      end
    end
  end

  test "V2 surface does not render the V1 Forecast::Workspace" do
    with_v2_global(true) do
      with_v2_family_ids([ @family.id.to_s ]) do
        Forecast::Workspace.expects(:new).never

        get forecast_url

        assert_response :success
        assert_inertia_component "Forecast/Workspace"
      end
    end
  end

  test "V2 props carry the family currency context derived server-side" do
    with_v2_global(true) do
      with_v2_family_ids([ @family.id.to_s ]) do
        get forecast_url

        assert_response :success
        assert_equal @family.primary_currency_code, inertia.props.dig(:plan, :reporting_currency)
      end
    end
  end

  private
    def with_v2_global(value)
      original = Rails.configuration.x.forecast_v2.enabled
      Rails.configuration.x.forecast_v2.enabled = value
      yield
    ensure
      Rails.configuration.x.forecast_v2.enabled = original
    end

    def with_v2_family_ids(ids)
      original = Rails.configuration.x.forecast_v2.family_ids
      Rails.configuration.x.forecast_v2.family_ids = ids.to_set.freeze
      yield
    ensure
      Rails.configuration.x.forecast_v2.family_ids = original
    end

    def enable_user_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("forecast_v2_preview" => true))
    end
end
