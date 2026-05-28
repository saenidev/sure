require "test_helper"

class Forecast::AccountsInputBuilderTest < ActiveSupport::TestCase
  test "returns included accounts with source snapshots" do
    family = families(:dylan_family)
    user = users(:family_admin)
    included_scope = Forecast::IncludedAccountScope.new(family: family, user: user)

    rows = Forecast::AccountsInputBuilder.new(
      family: family,
      user: user,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      scenario_ids: [],
      included_account_scope: included_scope
    ).call

    assert_equal included_scope.id_values.sort, rows.map { |row| row.fetch(:id) }.sort
    assert rows.all? { |row| row.fetch(:source_snapshot).present? }
  end
end
