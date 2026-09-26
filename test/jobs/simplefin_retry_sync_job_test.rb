require "test_helper"

class SimplefinRetrySyncJobTest < ActiveJob::TestCase
  setup do
    @item = SimplefinItem.create!(
      family: families(:dylan_family),
      name: "SimpleFIN Retry Test",
      access_url: "https://example.com/access"
    )
  end

  test "queues a new sync for the item" do
    assert_difference "@item.syncs.count", 1 do
      SimplefinRetrySyncJob.perform_now(@item)
    end
  end

  test "does not sync an item scheduled for deletion" do
    @item.update!(scheduled_for_deletion: true)

    assert_no_difference "@item.syncs.count" do
      SimplefinRetrySyncJob.perform_now(@item)
    end
  end
end
