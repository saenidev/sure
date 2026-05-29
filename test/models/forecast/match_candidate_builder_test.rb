require "test_helper"

class Forecast::MatchCandidateBuilderTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    @today = Date.current
    # Start from a clean slate so fixture entries do not leak into the window.
    Entry.where(account_id: @family.accounts.select(:id)).delete_all
    @family.forecast_event_links.delete_all
    @family.forecast_events.delete_all
  end

  def build_event(overrides = {})
    @family.forecast_events.create!({
      name: "Rent",
      effect_type: "expense",
      behavior: "additive",
      amount: 1000,
      currency: "USD",
      starts_on: @today,
      status: "planned",
      probability_weight: 1.0,
      account: @account,
      category: @category
    }.merge(overrides))
  end

  test "returns transaction entries within date and amount tolerance matching account and direction" do
    event = build_event
    # An outflow (positive signed amount) close to the event amount, on time.
    match = create_transaction(account: @account, amount: 1010, date: @today, name: "Landlord")

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_equal [ match.id ], candidates.map { |c| c.entry.id }
    assert candidates.first.confidence.positive?
    assert_includes candidates.first.reasons, "amount_within_tolerance"
    assert_includes candidates.first.reasons, "account_match"
  end

  test "excludes entries outside the date window" do
    event = build_event
    create_transaction(account: @account, amount: 1000, date: @today + 30.days, name: "Too late")

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_empty candidates
  end

  test "excludes entries with the wrong cash-flow direction" do
    # Income event expects an inflow (negative signed amount); a positive
    # (outflow) entry must not be proposed.
    event = build_event(effect_type: "income")
    create_transaction(account: @account, amount: 1000, date: @today, name: "An expense")

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_empty candidates
  end

  test "income event proposes inflow entries" do
    event = build_event(effect_type: "income")
    inflow = create_transaction(account: @account, amount: -1000, date: @today, name: "Paycheck")

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_equal [ inflow.id ], candidates.map { |c| c.entry.id }
  end

  test "excludes entries already claimed by an accepted link" do
    event = build_event
    claimed = create_transaction(account: @account, amount: 1000, date: @today, name: "Already linked")
    other_event = build_event(name: "Other rent")
    @family.forecast_event_links.create!(
      forecast_event: other_event,
      entry: claimed,
      occurrence_on: @today,
      link_type: "actual",
      status: "accepted"
    )

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_empty candidates, "an entry accepted-linked elsewhere must not be re-proposed"
  end

  test "excludes entries already linked to this event occurrence" do
    event = build_event
    linked = create_transaction(account: @account, amount: 1000, date: @today, name: "Pending link")
    @family.forecast_event_links.create!(
      forecast_event: event,
      entry: linked,
      occurrence_on: @today,
      link_type: "actual",
      status: "candidate"
    )

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_empty candidates
  end

  test "empty when there are no candidate entries" do
    event = build_event

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_empty candidates
  end

  test "never proposes another family's entries" do
    event = build_event
    foreign_account = accounts(:other_asset)
    foreign_account.update!(family: families(:empty), owner: users(:empty))
    Entry.create!(
      account: foreign_account, name: "Foreign", date: @today,
      amount: 1000, currency: "USD", entryable: Transaction.new
    )

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_empty candidates
  end

  test "non-directional market_shock event yields no candidates" do
    event = build_event(effect_type: "market_shock", amount: -500, account: nil, category: nil)
    create_transaction(account: @account, amount: 500, date: @today)

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_empty candidates
  end

  test "ranks closer matches with higher confidence" do
    event = build_event
    far = create_transaction(account: @account, amount: 1090, date: @today + 5.days, name: "Far")
    near = create_transaction(account: @account, amount: 1000, date: @today, name: "Near")

    candidates = Forecast::MatchCandidateBuilder.new(family: @family, event: event).call

    assert_equal [ near.id, far.id ], candidates.map { |c| c.entry.id }
    assert candidates.first.confidence > candidates.last.confidence
  end
end
