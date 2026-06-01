# frozen_string_literal: true

require "test_helper"

class Api::V1::HoldingsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @account = accounts(:investment)
    @security = securities(:aapl)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Holdings API Test",
      redirect_uri: "https://example.com/callback",
      scopes: "read"
    )

    @read_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )
  end

  test "index avoids avg cost queries per holding" do
    create_trade(@security, account: @account, qty: 10, date: 5.days.ago.to_date, price: 100)

    3.times do |idx|
      @account.holdings.create!(
        security: @security,
        date: (idx + 2).days.ago.to_date,
        qty: 10 + idx,
        price: 110 + idx,
        amount: (10 + idx) * (110 + idx),
        currency: "USD",
        cost_basis: nil,
        cost_basis_source: nil
      )
    end

    assert_queries_count(matcher: /SUM\(trades\.price \* trades\.qty/i, max: 1) do
      get "/api/v1/holdings", headers: bearer_auth_header(@read_token)
    end

    assert_response :success
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
