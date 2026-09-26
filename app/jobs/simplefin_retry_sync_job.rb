class SimplefinRetrySyncJob < ApplicationJob
  queue_as :high_priority

  def perform(simplefin_item)
    return if simplefin_item.scheduled_for_deletion?

    simplefin_item.sync_later
  end
end
