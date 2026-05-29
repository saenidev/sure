# Forecast configuration.
#
# Tunable thresholds and behavior for the scheduled forecast jobs
# (ForecastWeeklyReviewJob / ForecastMarketCloseJob) and the
# Forecast::MaterialMovement comparison PORO. Operators can override any of
# these via ENV without touching code; the defaults below are sane production
# values (see SLICE 11 spec). All thresholds are expressed as positive
# magnitudes — MaterialMovement compares the ABSOLUTE change against them, so a
# 5% drop is just as "material" as a 5% gain.
Rails.application.configure do
  config.x.forecast.tap do |forecast|
    # Material-movement thresholds for the market-close trigger. A run is
    # considered "material" (worth generating + flagging for human review) when
    # ANY of these is breached relative to the family's previous completed run
    # group's first projected day.
    #
    # portfolio_day_change_pct / net_worth_change_pct / debt_change_pct are
    # FRACTIONS (0.05 == 5%). cash_runway_change_days is an absolute day delta.
    forecast.material_portfolio_change_pct =
      ENV.fetch("FORECAST_MATERIAL_PORTFOLIO_CHANGE_PCT", "0.05").to_f
    forecast.material_net_worth_change_pct =
      ENV.fetch("FORECAST_MATERIAL_NET_WORTH_CHANGE_PCT", "0.03").to_f
    forecast.material_debt_change_pct =
      ENV.fetch("FORECAST_MATERIAL_DEBT_CHANGE_PCT", "0.05").to_f
    forecast.material_cash_runway_change_days =
      ENV.fetch("FORECAST_MATERIAL_CASH_RUNWAY_CHANGE_DAYS", "14").to_i

    # When the family has NO previous completed group to compare against (the
    # very first market-close evaluation), treat the movement as material so the
    # first market-close run is always generated rather than silently skipped.
    forecast.material_on_missing_baseline =
      ActiveModel::Type::Boolean.new.cast(
        ENV.fetch("FORECAST_MATERIAL_ON_MISSING_BASELINE", "true")
      )

    # Endpoint for the external Hermes planning agent. Blank by default — the
    # external send/receive round-trip is a STUBBED boundary in this build, so
    # Forecast::HermesClient#submit raises NotConfigured (handled gracefully by
    # the review UI) until an operator wires up a real endpoint.
    forecast.hermes_endpoint = ENV["FORECAST_HERMES_ENDPOINT"].presence
  end
end
