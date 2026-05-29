require "test_helper"

class Forecast::ReconciliationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @today = Date.current
    @family.forecast_event_links.delete_all
    @family.forecast_events.delete_all
  end

  def build_event(starts_on:, overrides: {})
    @family.forecast_events.create!({
      name: "Event #{starts_on}",
      effect_type: "expense",
      behavior: "additive",
      amount: 1000,
      currency: "USD",
      starts_on: starts_on,
      status: "planned",
      probability_weight: 1.0,
      account: @account
    }.merge(overrides))
  end

  def row_for(reconciliation, event)
    reconciliation.rows.find { |r| r.event.id == event.id }
  end

  test "a future event beyond the due-soon window is planned" do
    event = build_event(starts_on: @today + 30.days)

    reconciliation = Forecast::Reconciliation.new(family: @family)

    assert_equal "planned", row_for(reconciliation, event).lifecycle_state
  end

  test "an event within the due-soon window is due_soon" do
    event = build_event(starts_on: @today + 2.days)

    reconciliation = Forecast::Reconciliation.new(family: @family)

    assert_equal "due_soon", row_for(reconciliation, event).lifecycle_state
  end

  test "an event due today is due_soon" do
    event = build_event(starts_on: @today)

    reconciliation = Forecast::Reconciliation.new(family: @family)

    assert_equal "due_soon", row_for(reconciliation, event).lifecycle_state
  end

  test "an event with an accepted link is matched regardless of date" do
    event = build_event(starts_on: @today - 30.days)
    entry = create_transaction(account: @account, amount: 1000, date: @today - 30.days)
    @family.forecast_event_links.create!(
      forecast_event: event, entry: entry, occurrence_on: event.starts_on,
      link_type: "actual", status: "accepted"
    )

    reconciliation = Forecast::Reconciliation.new(family: @family)
    row = row_for(reconciliation, event)

    assert_equal "matched", row.lifecycle_state
    assert row.matched?
    assert_not_nil row.accepted_link
  end

  test "a past unmatched event is missed and does NOT mutate the event status" do
    event = build_event(starts_on: @today - 30.days)

    reconciliation = Forecast::Reconciliation.new(family: @family)

    assert_equal "missed", row_for(reconciliation, event).lifecycle_state
    # The reconciliation lifecycle is computed; the event's authoring status is
    # untouched.
    assert_equal "planned", event.reload.status
  end

  test "a candidate (non-accepted) link does not mark the occurrence matched" do
    event = build_event(starts_on: @today - 30.days)
    entry = create_transaction(account: @account, amount: 1000, date: @today - 30.days)
    @family.forecast_event_links.create!(
      forecast_event: event, entry: entry, occurrence_on: event.starts_on,
      link_type: "actual", status: "candidate"
    )

    reconciliation = Forecast::Reconciliation.new(family: @family)

    assert_equal "missed", row_for(reconciliation, event).lifecycle_state
  end

  test "counts summarize lifecycle states" do
    build_event(starts_on: @today + 30.days)               # planned
    build_event(starts_on: @today + 2.days)                # due_soon
    build_event(starts_on: @today - 30.days)               # missed

    reconciliation = Forecast::Reconciliation.new(family: @family)

    assert_equal 1, reconciliation.counts["planned"]
    assert_equal 1, reconciliation.counts["due_soon"]
    assert_equal 1, reconciliation.counts["missed"]
    assert_equal 0, reconciliation.counts["matched"]
  end

  test "empty when the family has no events" do
    reconciliation = Forecast::Reconciliation.new(family: @family)

    assert reconciliation.empty?
    assert_empty reconciliation.rows
  end

  test "only includes the current family's events" do
    mine = build_event(starts_on: @today)
    families(:empty).forecast_events.create!(
      name: "Foreign", effect_type: "expense", behavior: "additive",
      amount: 10, currency: "USD", starts_on: @today, status: "planned"
    )

    reconciliation = Forecast::Reconciliation.new(family: @family)

    assert_equal [ mine.id ], reconciliation.rows.map { |r| r.event.id }
  end
end
