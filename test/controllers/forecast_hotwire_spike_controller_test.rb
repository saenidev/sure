require "test_helper"

# THROWAWAY spike coverage — delete with forecast_hotwire_spike.
class ForecastHotwireSpikeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "show renders the plan workspace shell seeded from family data" do
    get forecast_hotwire_spike_path

    assert_response :success
    assert_select "[data-controller=?]", "forecast-spike"
    assert_select "#forecast-spike-data"
    assert_select "#forecast-spike-metrics"
    assert_select "#forecast-spike-explanation"
    assert_select "#forecast-spike-card-income_monthly form"
    assert_select "[data-forecast-spike-currency-value]"
  end

  test "saving an assumption streams only scoped region updates" do
    patch forecast_hotwire_spike_assumption_path,
      params: { key: "income_monthly", value: 20_000, period_index: 30 },
      as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    %w[forecast-spike-data forecast-spike-metrics forecast-spike-explanation
       forecast-spike-card-income_monthly forecast-spike-freshness].each do |target|
      assert_select "turbo-stream[action=replace][target=?]", target
    end
    # The shell is never re-rendered — only turbo-stream fragments come back.
    assert_select "[data-controller=forecast-spike]", count: 0
  end

  test "edits persist across the round trip via the session" do
    patch forecast_hotwire_spike_assumption_path,
      params: { key: "income_monthly", value: 25_000, period_index: 0 },
      as: :turbo_stream
    assert_response :success

    get forecast_hotwire_spike_path
    assert_select "#forecast-spike-card-income_monthly", text: /25,000/
  end
end
