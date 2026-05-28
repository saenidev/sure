require "test_helper"

class Forecast::IncludedAccountScopeTest < ActiveSupport::TestCase
  test "matches Sure included-in-finances account scope" do
    family = families(:dylan_family)
    user = users(:family_admin)

    expected = family.accounts.visible.included_in_finances_for(user).pluck(:id).sort
    actual = Forecast::IncludedAccountScope.new(family: family, user: user).id_values.sort

    assert_equal expected, actual
  end
end
