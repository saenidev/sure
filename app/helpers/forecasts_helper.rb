module ForecastsHelper
  # DS::Pill tone for a ForecastReview status. Centralizes the status -> color
  # mapping so the review templates stay declarative (no tone logic in views).
  REVIEW_STATUS_TONES = {
    "draft" => :gray,
    "awaiting_approval" => :amber,
    "approved" => :indigo,
    "rejected" => :fuchsia,
    "applied" => :indigo,
    "superseded" => :gray
  }.freeze

  # Maps each workspace tab id to the partial rendering its panel body. Owned
  # here (the view-facing tab metadata) and referenced by ForecastsController#tab
  # to validate the requested tab, so the allowlist lives in exactly one place.
  # Note `review` maps to the review_history partial (tab id and partial differ).
  TAB_PARTIALS = {
    "outlook" => "forecasts/outlook",
    "what_if" => "forecasts/what_if",
    "inputs" => "forecasts/inputs",
    "reconcile" => "forecasts/reconcile",
    "history" => "forecasts/history"
  }.freeze

  # Tabs whose panels derive purely from the immutable persisted run group (no
  # forms/CSRF, no live planning data), so their HTML can be fragment-cached on
  # the run group. A new generation creates a new run group, rolling the key.
  CACHEABLE_TABS = [].freeze

  def review_status_tone(status)
    REVIEW_STATUS_TONES.fetch(status, :gray)
  end

  # Frame id wrapping a single workspace tab panel. Matches between the show
  # page's placeholder frame and the #tab endpoint's response so Turbo swaps the
  # loaded body in place.
  def forecast_tab_frame_id(tab_id)
    "forecast_tab_#{tab_id}"
  end
end
