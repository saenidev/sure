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

  def review_status_tone(status)
    REVIEW_STATUS_TONES.fetch(status, :gray)
  end
end
