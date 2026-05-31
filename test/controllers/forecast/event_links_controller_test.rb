require "test_helper"

class Forecast::EventLinksControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    @today = Date.current
    Entry.where(account_id: @family.accounts.select(:id)).delete_all
    @family.forecast_event_links.delete_all
    @family.forecast_events.delete_all
    sign_in @user
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

  def foreign_family
    families(:empty)
  end

  # --- index -----------------------------------------------------------------

  test "index renders the reconciliation tab for the family" do
    event = build_event
    create_transaction(account: @account, amount: 1000, date: @today, name: "Landlord")

    get forecast_event_links_path

    assert_response :success
    assert_select "[data-testid=reconciliation-work-queue]"
    assert_select "##{dom_id(event, :reconciliation)}"
  end

  test "index renders an empty state when the family has no events" do
    get forecast_event_links_path

    assert_response :success
    assert_select "[data-testid=reconciliation-empty-state]"
  end

  test "index does not surface another family's events" do
    foreign = foreign_family.forecast_events.create!(
      name: "Foreign", effect_type: "expense", behavior: "additive",
      amount: 5, currency: "USD", starts_on: @today, status: "planned"
    )

    get forecast_event_links_path

    assert_response :success
    assert_select "##{dom_id(foreign, :reconciliation)}", count: 0
  end

  # --- create (accept a candidate) -------------------------------------------

  test "accepting a candidate creates an accepted link with persisted snapshots" do
    event = build_event
    entry = create_transaction(account: @account, amount: 1000, date: @today, name: "Landlord")

    assert_difference "@family.forecast_event_links.count", 1 do
      post forecast_event_links_path, params: { forecast_event_link: {
        forecast_event_id: event.id,
        entry_id: entry.id,
        occurrence_on: event.starts_on.iso8601,
        link_type: "actual",
        confidence: "0.85"
      } }
    end

    assert_redirected_to forecast_event_links_path
    link = @family.forecast_event_links.order(:created_at).last
    assert_equal "accepted", link.status
    assert_equal event.id, link.forecast_event_id
    assert_equal entry.id, link.entry_id
    assert_equal event.id, link.event_snapshot["id"]
    assert_equal entry.id, link.entry_snapshot["id"]
  end

  # --- create validation / failure surfacing ---------------------------------

  test "accepting a non-transaction (valuation) entry is rejected" do
    event = build_event
    valuation = create_valuation(account: @account, amount: 4000)

    assert_no_difference "@family.forecast_event_links.count" do
      post forecast_event_links_path, params: { forecast_event_link: {
        forecast_event_id: event.id,
        entry_id: valuation.id,
        occurrence_on: event.starts_on.iso8601
      } }
    end

    assert_redirected_to forecast_event_links_path
    follow_redirect!
    assert_select "[data-testid=reconciliation-empty-state]", count: 0
  end

  test "a second accepted link for the same entry is rejected (uniqueness)" do
    event = build_event
    other_event = build_event(name: "Other")
    entry = create_transaction(account: @account, amount: 1000, date: @today)
    @family.forecast_event_links.create!(
      forecast_event: event, entry: entry, occurrence_on: event.starts_on,
      link_type: "actual", status: "accepted"
    )

    assert_no_difference "@family.forecast_event_links.where(status: 'accepted').count" do
      post forecast_event_links_path, params: { forecast_event_link: {
        forecast_event_id: other_event.id,
        entry_id: entry.id,
        occurrence_on: other_event.starts_on.iso8601
      } }
    end

    assert_redirected_to forecast_event_links_path
  end

  test "a second accepted link for the same (event, occurrence) is rejected" do
    event = build_event
    first_entry = create_transaction(account: @account, amount: 1000, date: @today, name: "First")
    second_entry = create_transaction(account: @account, amount: 1000, date: @today, name: "Second")
    @family.forecast_event_links.create!(
      forecast_event: event, entry: first_entry, occurrence_on: event.starts_on,
      link_type: "actual", status: "accepted"
    )

    assert_no_difference "@family.forecast_event_links.where(status: 'accepted').count" do
      post forecast_event_links_path, params: { forecast_event_link: {
        forecast_event_id: event.id,
        entry_id: second_entry.id,
        occurrence_on: event.starts_on.iso8601
      } }
    end

    assert_redirected_to forecast_event_links_path
  end

  # --- update (status transition / immutability) ------------------------------

  test "superseding an accepted link transitions its status" do
    event = build_event
    entry = create_transaction(account: @account, amount: 1000, date: @today)
    link = @family.forecast_event_links.create!(
      forecast_event: event, entry: entry, occurrence_on: event.starts_on,
      link_type: "actual", status: "accepted"
    )

    patch forecast_event_link_path(link), params: { forecast_event_link: { status: "superseded" } }

    assert_redirected_to forecast_event_links_path
    assert_equal "superseded", link.reload.status
  end

  test "attempting to repoint an accepted link's entry is blocked by immutability" do
    event = build_event
    entry = create_transaction(account: @account, amount: 1000, date: @today, name: "Original")
    other_entry = create_transaction(account: @account, amount: 1000, date: @today, name: "Hijack")
    link = @family.forecast_event_links.create!(
      forecast_event: event, entry: entry, occurrence_on: event.starts_on,
      link_type: "actual", status: "accepted"
    )

    # entry_id is not a permitted update param, but assert the model invariant
    # holds even if it were attempted directly.
    link.entry_id = other_entry.id
    assert_not link.valid?(:update)
    assert link.errors.added?(:base, "accepted forecast event links cannot change linked records or snapshots")
    assert_equal entry.id, link.reload.entry_id
  end

  # --- destroy ----------------------------------------------------------------

  test "destroy removes the link" do
    event = build_event
    entry = create_transaction(account: @account, amount: 1000, date: @today)
    link = @family.forecast_event_links.create!(
      forecast_event: event, entry: entry, occurrence_on: event.starts_on,
      link_type: "actual", status: "accepted"
    )

    assert_difference "@family.forecast_event_links.count", -1 do
      delete forecast_event_link_path(link)
    end

    assert_redirected_to forecast_event_links_path
  end

  # --- authorization / cross-family denial -----------------------------------

  test "accepting a foreign entry is denied with a 404" do
    event = build_event
    foreign_account = accounts(:other_asset)
    foreign_account.update!(family: foreign_family, owner: users(:empty))
    foreign_entry = Entry.create!(
      account: foreign_account, name: "Foreign", date: @today,
      amount: 1000, currency: "USD", entryable: Transaction.new
    )

    assert_no_difference "ForecastEventLink.count" do
      post forecast_event_links_path, params: { forecast_event_link: {
        forecast_event_id: event.id,
        entry_id: foreign_entry.id,
        occurrence_on: event.starts_on.iso8601
      } }
    end

    assert_response :not_found
  end

  test "accepting onto a foreign event is denied with a 404" do
    foreign_event = foreign_family.forecast_events.create!(
      name: "Foreign", effect_type: "expense", behavior: "additive",
      amount: 5, currency: "USD", starts_on: @today, status: "planned"
    )
    entry = create_transaction(account: @account, amount: 1000, date: @today)

    assert_no_difference "ForecastEventLink.count" do
      post forecast_event_links_path, params: { forecast_event_link: {
        forecast_event_id: foreign_event.id,
        entry_id: entry.id,
        occurrence_on: @today.iso8601
      } }
    end

    assert_response :not_found
  end

  test "updating a foreign link id is denied with a 404" do
    foreign_event = foreign_family.forecast_events.create!(
      name: "Foreign", effect_type: "expense", behavior: "additive",
      amount: 5, currency: "USD", starts_on: @today, status: "planned"
    )
    foreign_link = foreign_family.forecast_event_links.create!(
      forecast_event: foreign_event, occurrence_on: @today,
      link_type: "actual", status: "candidate"
    )

    patch forecast_event_link_path(foreign_link), params: { forecast_event_link: { status: "rejected" } }

    assert_response :not_found
    assert_equal "candidate", foreign_link.reload.status
  end

  test "destroying a foreign link id is denied with a 404" do
    foreign_event = foreign_family.forecast_events.create!(
      name: "Foreign", effect_type: "expense", behavior: "additive",
      amount: 5, currency: "USD", starts_on: @today, status: "planned"
    )
    foreign_link = foreign_family.forecast_event_links.create!(
      forecast_event: foreign_event, occurrence_on: @today,
      link_type: "actual", status: "candidate"
    )

    assert_no_difference "ForecastEventLink.count" do
      delete forecast_event_link_path(foreign_link)
    end

    assert_response :not_found
  end

  test "create cannot set family_id via params" do
    event = build_event
    entry = create_transaction(account: @account, amount: 1000, date: @today)

    post forecast_event_links_path, params: { forecast_event_link: {
      forecast_event_id: event.id,
      entry_id: entry.id,
      occurrence_on: event.starts_on.iso8601,
      family_id: foreign_family.id
    } }

    link = @family.forecast_event_links.order(:created_at).last
    assert_equal @family.id, link.family_id
    assert_equal 0, foreign_family.forecast_event_links.count
  end

  # --- variance ---------------------------------------------------------------

  test "variance view shows amount and date deltas from the snapshots" do
    event = build_event(amount: 1000, starts_on: @today - 2.days)
    # Actual differs in amount and date from the expected.
    entry = create_transaction(account: @account, amount: 1100, date: @today, name: "Landlord")
    @family.forecast_event_links.create!(
      forecast_event: event, entry: entry, occurrence_on: event.starts_on,
      link_type: "actual", status: "accepted"
    )

    get forecast_event_links_path

    assert_response :success
    assert_select "[data-testid=reconciliation-summary]"
    # The matched row renders the variance panel rather than candidates.
    assert_select "##{dom_id(event, :reconciliation)} [data-testid='#{dom_id(@family.forecast_event_links.last, :variance)}']"
  end
end
