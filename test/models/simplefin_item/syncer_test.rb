require "test_helper"

class SimplefinItem::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @item = SimplefinItem.create!(
      family: families(:dylan_family),
      name: "SimpleFIN Syncer Test",
      access_url: "https://example.com/access"
    )
    simplefin_account = @item.simplefin_accounts.create!(
      name: "Checking",
      account_id: "sf_syncer_checking",
      account_type: "checking",
      currency: "USD",
      current_balance: 100
    )
    accounts(:depository).update!(simplefin_account_id: simplefin_account.id)

    @syncer = SimplefinItem::Syncer.new(@item)
  end

  test "schedules one delayed retry when the sync fails with a SimpleFIN server error" do
    sync = @item.syncs.create!(status: :syncing)
    @item.expects(:import_latest_simplefin_data).raises(simplefin_error(:server_error))

    travel_to Time.zone.local(2026, 9, 20, 2, 22) do
      assert_enqueued_jobs 1, only: SimplefinRetrySyncJob do
        assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
      end

      assert_enqueued_with job: SimplefinRetrySyncJob, args: [ @item ], at: SimplefinItem::Syncer::AUTO_RETRY_DELAY.from_now
    end
  end

  test "schedules a retry for rate limits and network failures" do
    %i[rate_limited request_failed network_error].each do |error_type|
      clear_enqueued_jobs
      sync = @item.syncs.create!(status: :syncing)
      @item.expects(:import_latest_simplefin_data).raises(simplefin_error(error_type))

      assert_enqueued_jobs 1, only: SimplefinRetrySyncJob do
        assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
      end
    end
  end

  test "does not retry non-transient SimpleFIN errors" do
    %i[access_forbidden payment_required bad_request token_compromised].each do |error_type|
      sync = @item.syncs.create!(status: :syncing)
      @item.expects(:import_latest_simplefin_data).raises(simplefin_error(error_type))

      assert_no_enqueued_jobs only: SimplefinRetrySyncJob do
        assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
      end
    end
  end

  test "stops scheduling retries once the recent retry budget is spent" do
    SimplefinItem::Syncer::MAX_AUTO_RETRIES.times do |i|
      @item.syncs.create!(status: :failed, error: "SimpleFin server error (503)", created_at: (i + 1).hours.ago)
    end
    sync = @item.syncs.create!(status: :syncing)
    @item.expects(:import_latest_simplefin_data).raises(simplefin_error(:server_error))

    assert_no_enqueued_jobs only: SimplefinRetrySyncJob do
      assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
    end
  end

  test "failures outside the retry window do not consume the retry budget" do
    SimplefinItem::Syncer::MAX_AUTO_RETRIES.times do
      @item.syncs.create!(status: :failed, error: "SimpleFin server error (503)", created_at: 2.days.ago)
    end
    sync = @item.syncs.create!(status: :syncing)
    @item.expects(:import_latest_simplefin_data).raises(simplefin_error(:server_error))

    assert_enqueued_jobs 1, only: SimplefinRetrySyncJob do
      assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
    end
  end

  test "a transient failure through Sync#perform fails the sync and schedules a retry" do
    sync = @item.syncs.create!
    @item.expects(:import_latest_simplefin_data).raises(simplefin_error(:server_error))

    assert_enqueued_jobs 1, only: SimplefinRetrySyncJob do
      sync.perform
    end

    assert_equal "failed", sync.reload.status
    assert_equal "SimpleFin server error (503). Please try again later.", sync.error
  end

  private
    def simplefin_error(error_type)
      message = error_type == :server_error ? "SimpleFin server error (503). Please try again later." : "SimpleFin #{error_type}"
      Provider::Simplefin::SimplefinError.new(message, error_type)
    end
end
