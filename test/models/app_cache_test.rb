require "test_helper"

class AppCacheTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    Current.app_cache_versions = nil
  end

  test "user data key changes when an old entry is deleted" do
    account = @family.accounts.first
    older_entry = create_transaction(account: account, name: "Old cached entry", date: 2.months.ago.to_date)
    create_transaction(account: account, name: "Newest cached entry", date: Date.current)

    before_key = AppCache.user_data_key(family: @family, user: @user, namespace: "test")

    older_entry.destroy!
    @family.remove_instance_variable(:@entries_cache_version) if @family.instance_variable_defined?(:@entries_cache_version)
    Current.app_cache_versions = nil

    after_key = AppCache.user_data_key(family: @family, user: @user, namespace: "test")

    refute_equal before_key, after_key
  end

  test "user data key changes when account access changes" do
    guest = family_guest
    account = @family.accounts.first

    before_key = AppCache.user_data_key(family: @family, user: guest, namespace: "test")

    account.account_shares.create!(user: guest, permission: "read_only", include_in_finances: true)
    Current.app_cache_versions = nil

    after_key = AppCache.user_data_key(family: @family, user: guest, namespace: "test")

    refute_equal before_key, after_key
  end

  test "user data key memoizes repeated version lookups in the current request" do
    Current.session = sessions(:one)
    AppCache.expects(:relation_version).times(4).returns("v")

    2.times do
      AppCache.user_data_key(
        family: @family,
        user: @user,
        namespace: "test",
        versions: %i[family accounts categories account_shares]
      )
    end
  end
end
