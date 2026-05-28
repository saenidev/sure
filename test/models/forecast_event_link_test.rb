require "test_helper"

class ForecastEventLinkTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @event = @family.forecast_events.build(
      name: "Future invoice",
      effect_type: "income",
      behavior: "additive",
      amount: 1000,
      currency: "USD",
      starts_on: Date.current
    )
    @event.save!
  end

  test "links a planned event to an actual entry in the same family" do
    link = @family.forecast_event_links.build(
      forecast_event: @event,
      entry: entries(:transaction),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    assert link.valid?
    link.save!
    assert_equal @event.starts_on, link.occurrence_on
    assert_equal entries(:transaction).id, link.entry_snapshot.fetch("id")
    assert_equal entries(:transaction).transaction.kind, link.entry_snapshot.fetch("transaction_kind")
  end

  test "accepted recurring links are unique per occurrence" do
    @event.update!(recurrence_rule: { "frequency" => "monthly", "day_of_month" => @event.starts_on.day })
    @family.forecast_event_links.create!(
      forecast_event: @event,
      entry: entries(:transaction),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    duplicate = @family.forecast_event_links.build(
      forecast_event: @event,
      entry: entries(:transfer_out),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    next_occurrence = @family.forecast_event_links.build(
      forecast_event: @event,
      entry: entries(:transfer_in),
      occurrence_on: @event.starts_on.next_month,
      link_type: "actual",
      status: "accepted"
    )

    assert_not duplicate.valid?
    assert next_occurrence.valid?
  end

  test "accepted links are unique per real entry across forecast events" do
    other_event = @family.forecast_events.create!(
      name: "Another future invoice",
      effect_type: "income",
      behavior: "additive",
      amount: 1000,
      currency: "USD",
      starts_on: @event.starts_on
    )
    @family.forecast_event_links.create!(
      forecast_event: @event,
      entry: entries(:transaction),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )
    duplicate = @family.forecast_event_links.build(
      forecast_event: other_event,
      entry: entries(:transaction),
      occurrence_on: other_event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:entry_id], "already has an accepted forecast event link"
  end

  test "rejects an entry from another family" do
    entry = entries(:transaction)
    entry.account.update!(family: families(:empty), owner: users(:empty))

    link = @family.forecast_event_links.build(
      forecast_event: @event,
      entry: entry,
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    assert_not link.valid?
    assert_includes link.errors[:entry], "must belong to the forecast family"
  end

  test "accepted link keeps event snapshot if event is deleted" do
    link = @family.forecast_event_links.create!(
      forecast_event: @event,
      entry: entries(:transaction),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    @event.destroy!

    assert_nil link.reload.forecast_event_id
    assert_equal "Future invoice", link.event_snapshot.fetch("name")
    assert_equal entries(:transaction).id, link.entry_snapshot.fetch("id")
  end

  test "accepted link remains valid when linked entry is later deleted" do
    link = @family.forecast_event_links.create!(
      forecast_event: @event,
      entry: entries(:transaction),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    link.update_column(:entry_id, nil)

    assert link.reload.valid?
    assert_equal entries(:transaction).id, link.entry_snapshot.fetch("id")
  end

  test "accepted link does not rewrite snapshots when linked records later change" do
    entry = entries(:transaction)
    link = @family.forecast_event_links.create!(
      forecast_event: @event,
      entry: entry,
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted",
      confidence: 0.9
    )
    original_event_snapshot = link.event_snapshot
    original_entry_snapshot = link.entry_snapshot

    @event.update!(name: "Changed event name")
    entry.update!(name: "Changed entry name")
    link.update!(confidence: 0.8)

    assert_equal original_event_snapshot, link.reload.event_snapshot
    assert_equal original_entry_snapshot, link.entry_snapshot
  end

  test "accepted link cannot be reattached to a different entry" do
    link = @family.forecast_event_links.create!(
      forecast_event: @event,
      entry: entries(:transaction),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    assert_not link.update(entry: entries(:transfer_out))
    assert_includes link.errors[:base], "accepted forecast event links cannot change linked records or snapshots"
  end

  test "accepted link requires an entry that owns the cash effect" do
    link = @family.forecast_event_links.build(
      forecast_event: @event,
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    assert_not link.valid?
    assert_includes link.errors[:entry], "must be present for accepted links"
  end

  test "accepted link rejects non-transaction entries" do
    link = @family.forecast_event_links.build(
      forecast_event: @event,
      entry: entries(:valuation),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    assert_not link.valid?
    assert_includes link.errors[:entry], "must be a transaction entry for accepted links"
  end

  test "accepted link cannot rewrite audit snapshots" do
    link = @family.forecast_event_links.create!(
      forecast_event: @event,
      entry: entries(:transaction),
      occurrence_on: @event.starts_on,
      link_type: "actual",
      status: "accepted"
    )

    assert_not link.update(event_snapshot: { "name" => "changed" })
    assert_includes link.errors[:base], "accepted forecast event links cannot change linked records or snapshots"
  end
end
