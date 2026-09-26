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

  test "schedules a retry for network failures" do
    sync = @item.syncs.create!(status: :syncing)
    @item.expects(:import_latest_simplefin_data).raises(simplefin_error(:network_error))

    assert_enqueued_jobs 1, only: SimplefinRetrySyncJob do
      assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
    end
  end

  # A SimpleFIN 429 means the daily refresh quota is spent; retrying 45 minutes
  # later only burns more quota and fails again.
  test "does not retry a SimpleFIN rate limit" do
    sync = @item.syncs.create!(status: :syncing)
    @item.expects(:import_latest_simplefin_data).raises(simplefin_error(:rate_limited))

    assert_no_enqueued_jobs only: SimplefinRetrySyncJob do
      assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
    end
  end

  test "retries a request failure caused by a network or timeout error" do
    [
      Errno::EHOSTUNREACH.new("connect(2)"),
      Errno::ENETUNREACH.new("connect(2)"),
      Net::WriteTimeout.new("write timed out"),
      OpenSSL::SSL::SSLError.new("SSL_connect SYSCALL returned=5")
    ].each do |cause|
      clear_enqueued_jobs
      sync = @item.syncs.create!(status: :syncing)
      @item.expects(:import_latest_simplefin_data).raises(request_failed_error(cause))

      assert_enqueued_jobs 1, only: SimplefinRetrySyncJob do
        assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
      end
    end
  end

  test "does not retry a request failure caused by a programming or data error" do
    [ ArgumentError.new("bad uri"), NoMethodError.new("undefined method"), URI::InvalidURIError.new("bad access url") ].each do |cause|
      sync = @item.syncs.create!(status: :syncing)
      @item.expects(:import_latest_simplefin_data).raises(request_failed_error(cause))

      assert_no_enqueued_jobs only: SimplefinRetrySyncJob do
        assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
      end
    end
  end

  test "does not retry a request failure with no underlying cause" do
    sync = @item.syncs.create!(status: :syncing)
    @item.expects(:import_latest_simplefin_data).raises(simplefin_error(:request_failed))

    assert_no_enqueued_jobs only: SimplefinRetrySyncJob do
      assert_raises(Provider::Simplefin::SimplefinError) { @syncer.perform_sync(sync) }
    end
  end

  test "a real provider request failure keeps the network error as its cause" do
    Provider::Simplefin.stubs(:get).raises(Errno::EHOSTUNREACH.new("connect(2)"))

    error = assert_raises(Provider::Simplefin::SimplefinError) do
      Provider::Simplefin.new.get_accounts("https://example.com/access")
    end

    assert_equal :request_failed, error.error_type
    assert_kind_of Errno::EHOSTUNREACH, error.cause
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
    # Mirrors Provider::Simplefin#with_retries, which wraps unexpected
    # exceptions in a :request_failed SimplefinError raised from the rescue, so
    # Ruby records the original exception as the cause.
    def request_failed_error(cause)
      begin
        raise cause
      rescue
        raise Provider::Simplefin::SimplefinError.new("Exception during GET /accounts: #{cause.message}", :request_failed)
      end
    rescue Provider::Simplefin::SimplefinError => e
      e
    end

    def simplefin_error(error_type)
      message = error_type == :server_error ? "SimpleFin server error (503). Please try again later." : "SimpleFin #{error_type}"
      Provider::Simplefin::SimplefinError.new(message, error_type)
    end
end
