require "test_helper"
require "action_view/dependency_tracker"

class AccountSidebarTabsDigestTest < ActiveSupport::TestCase
  test "cached sidebar does not ask Rails to digest ViewComponent constants as partials" do
    lookup = ActionView::LookupContext.new(ActionController::Base.view_paths)
    template = lookup.find("accounts/account_sidebar_tabs", [], true)

    dependencies = ActionView::DependencyTracker.find_dependencies(
      "accounts/account_sidebar_tabs",
      template,
      lookup.view_paths
    )

    refute_includes dependencies, "Ds/D"
  end
end
