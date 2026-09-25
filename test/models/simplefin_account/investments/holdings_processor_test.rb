require "test_helper"

class SimplefinAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)
  end

  test "cost_basis source is used unchanged as per share basis" do
    payload = {
      "cost_basis" => "16.61",
      "total_cost" => "9588.61",
      "value" => "10108.16"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("16.61"), cost_basis
    assert_equal "cost_basis", source_key
  end

  test "basis source is used unchanged as per share basis" do
    payload = {
      "basis" => "16.61",
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("16.61"), cost_basis
    assert_equal "basis", source_key
  end

  test "total_cost source is normalized to per share basis" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("9588.61") / BigDecimal("577.279"), cost_basis
    assert_equal "total_cost", source_key
  end

  test "value source is normalized to per share basis" do
    payload = {
      "value" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("9588.61") / BigDecimal("577.279"), cost_basis
    assert_equal "value", source_key
  end

  test "total cost source with zero quantity returns nil" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("0"), source_key)

    assert_nil cost_basis
    assert_equal "total_cost", source_key
  end

  test "total cost source with nil quantity returns nil" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, nil, source_key)

    assert_nil cost_basis
    assert_equal "total_cost", source_key
  end

  test "cost_basis from a known total-basis institution is divided by qty" do
    # Issue #1718 / #1182: Vanguard populates cost_basis with the total
    # position cost. When the institution is on the allowlist we divide.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("22004.40"),
      BigDecimal("139.00"),
      "cost_basis",
      true # institution_reports_total_basis?
    )

    assert_in_delta 158.30, cost_basis.to_f, 0.01
  end

  test "basis from a known total-basis institution is divided by qty" do
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("9000.00"),
      BigDecimal("200"),
      "basis",
      true
    )

    assert_equal BigDecimal("45.00"), cost_basis
  end

  test "cost_basis from a compliant institution is kept untouched (no false divide)" do
    # Codex regression: a legitimate per-share basis on a holding with a
    # large unrealized loss (e.g. $100/share basis now worth $5/share) must
    # NOT be divided by qty. Per the SimpleFIN spec, cost_basis is per-share
    # — only the institution allowlist should override that.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("100.00"),
      BigDecimal("100"),
      "cost_basis",
      false
    )

    assert_equal BigDecimal("100.00"), cost_basis
  end

  test "institution_reports_total_basis? matches Vanguard, Fidelity, Schwab, and E*Trade org metadata" do
    cases = {
      { "name" => "Vanguard" }                          => true,
      { "name" => "VANGUARD BROKERAGE" }                => true,
      { "name" => "Fidelity Investments" }              => true,
      { "domain" => "vanguard.com" }                    => true,
      { "domain" => "401k.fidelity.com" }               => true,
      # Schwab sends cost_basis = purchase_price * shares (total position
      # cost) in real SimpleFIN payloads, violating the per-share spec.
      { "name" => "Charles Schwab US", "domain" => "client.schwab.com" } => true,
      { "name" => "Charles Schwab", "domain" => "schwab.com" } => true,
      { "name" => "E*Trade" }                           => true,
      { "domain" => "us.etrade.com" }                   => true,
      { "name" => "Chase" }                             => false,
      {}                                                => false
    }

    cases.each do |org, expected|
      account = Struct.new(:org_data).new(org)
      processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)
      assert_equal expected,
        processor.send(:institution_reports_total_basis?),
        "org_data #{org.inspect} expected #{expected}"
    end
  end

  test "cost_basis from Charles Schwab is divided by qty (#2626)" do
    # Schwab reports `cost_basis` as the total position cost, not per-share,
    # in violation of the SimpleFIN spec — same failure mode as Vanguard
    # (#1182) and Fidelity (#1718). Observed on two independent Sure
    # instances via raw SimpleFIN payloads, e.g.:
    #   { "shares" => "651.00", "cost_basis" => "30162.36", "purchase_price" => "46.33235" }
    # Left uncorrected, Holding#calculate_trend later multiplies this
    # (mislabeled-as-per-share) total by qty again when reconstructing the
    # position's original cost, inflating a holding's unrealized loss by
    # roughly qty× — e.g. a $46,950 position showing a -99.8% / -$19.6M
    # "return" instead of its true +55.7% gain.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("30162.36"),
      BigDecimal("651"),
      "cost_basis",
      true # institution_reports_total_basis?
    )

    assert_in_delta 46.33, cost_basis.to_f, 0.01
  end

  test "cost_basis from E*Trade is divided by qty (#3618)" do
    # Same failure mode as Vanguard/Fidelity (#1718) and Schwab (#2626):
    # E*Trade's cost_basis is total position cost, not per-share.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("3850.00"),
      BigDecimal("100"),
      "cost_basis",
      true # institution_reports_total_basis?
    )

    assert_in_delta 38.50, cost_basis.to_f, 0.01
  end

  test "missing cost basis fields return nil" do
    payload = {
      "market_value" => "10108.16"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_nil raw_cost_basis
    assert_nil source_key
    assert_nil cost_basis
  end

  test "lots of the same security combine into one position" do
    # SimpleFIN reports one record per lot. A 401k splitting employee deferral
    # from employer match sends two records for the same fund, and `holdings` is
    # uniquely indexed on (account_id, security_id, date, currency), so importing
    # them separately made the second overwrite the first.
    security = securities(:aapl)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)

    processor.stubs(:holdings_data).returns([
      { "id" => "lot-b", "symbol" => "AAPL", "shares" => "11.891485", "market_value" => "3070.14", "cost_basis" => "200.00" },
      { "id" => "lot-a", "symbol" => "AAPL", "shares" => "2.378397",  "market_value" => "614.05",  "cost_basis" => "250.00" }
    ])
    processor.stubs(:account).returns(accounts(:investment))
    processor.stubs(:resolve_security).returns(security)
    processor.stubs(:institution_reports_total_basis?).returns(false)

    # The processor logs simplefin_account.id per lot, so the stub has to
    # answer it as well as account_provider.
    processor.stubs(:simplefin_account).returns(
      stub(id: "sfa-test", name: "Test Investment Account", account_provider: nil)
    )

    # A plain recorder rather than a mocha argument matcher, so the assertions
    # read against the real keyword arguments.
    recorder = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def import_holding(**kwargs)
        @calls << kwargs
        Struct.new(:id, :security_id, :qty, :amount, :currency, :date, :external_id)
              .new("h", kwargs[:security].id, kwargs[:quantity], kwargs[:amount],
                   kwargs[:currency], kwargs[:date], kwargs[:external_id])
      end
    end.new

    processor.stubs(:import_adapter).returns(recorder)

    processor.process

    assert_equal 1, recorder.calls.size, "expected the two lots to collapse into a single position"

    position = recorder.calls.first
    assert_in_delta 14.269882, position[:quantity].to_f, 0.000001
    assert_in_delta 3684.19,   position[:amount].to_f,   0.01

    # cost_basis is stored per share, so lots combine as a share-weighted
    # average: (11.891485*200 + 2.378397*250) / 14.269882
    assert_in_delta 208.333, position[:cost_basis].to_f, 0.01

    # price is re-derived from the combined position
    assert_in_delta 258.1781, position[:price].to_f, 0.01
  end

  test "a position with any unknown-basis lot reports no aggregate basis" do
    # Averaging only the lots that reported a basis would apply that figure to
    # shares whose cost is unknown, fabricating cost and gain/loss.
    security = securities(:aapl)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)

    processor.stubs(:holdings_data).returns([
      { "id" => "lot-known",   "symbol" => "AAPL", "shares" => "10", "market_value" => "2000.00", "cost_basis" => "100.00" },
      { "id" => "lot-unknown", "symbol" => "AAPL", "shares" => "10", "market_value" => "2000.00" }
    ])
    processor.stubs(:account).returns(accounts(:investment))
    processor.stubs(:resolve_security).returns(security)
    processor.stubs(:institution_reports_total_basis?).returns(false)
    processor.stubs(:simplefin_account).returns(
      stub(id: "sfa-test", name: "Test Investment Account", account_provider: nil)
    )

    recorder = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def import_holding(**kwargs)
        @calls << kwargs
        Struct.new(:id, :security_id, :qty, :amount, :currency, :date, :external_id)
              .new("h", kwargs[:security].id, kwargs[:quantity], kwargs[:amount],
                   kwargs[:currency], kwargs[:date], kwargs[:external_id])
      end
    end.new

    processor.stubs(:import_adapter).returns(recorder)

    processor.process

    assert_equal 1, recorder.calls.size
    position = recorder.calls.first

    # quantity and value still aggregate
    assert_in_delta 20.0,   position[:quantity].to_f, 0.000001
    assert_in_delta 4000.0, position[:amount].to_f,   0.01

    # but the basis is unknown for the position as a whole, NOT $100/share
    assert_nil position[:cost_basis]
  end

  test "a position reported at zero shares and zero value is imported as closed" do
    # SimpleFIN keeps reporting a sold position at 0 shares / $0 (Schwab does
    # this). Skipping it left the last non-zero snapshot as the latest provider
    # holding, so a fully sold position kept showing as held.
    processor = build_recording_processor([
      { "id" => "HOL-sold", "symbol" => "AAPL", "shares" => "0.00", "market_value" => "0.00",
        "cost_basis" => "74846.44", "purchase_price" => "61.049299" }
    ])

    processor.process

    assert_equal 1, @recorder.calls.size, "a closed position must still be written"
    position = @recorder.calls.first
    assert_equal 0, position[:quantity].to_d
    assert_equal 0, position[:amount].to_d
    assert_equal "simplefin_HOL-sold", position[:external_id]
    # With no shares there is nothing to average a per-share basis over.
    assert_nil position[:cost_basis]
  end

  test "a closed lot does not reduce or rename a position with open lots" do
    processor = build_recording_processor([
      { "id" => "lot-a-closed", "symbol" => "AAPL", "shares" => "0", "market_value" => "0" },
      { "id" => "lot-b-open",   "symbol" => "AAPL", "shares" => "10", "market_value" => "2000.00", "cost_basis" => "150.00" }
    ])

    processor.process

    assert_equal 1, @recorder.calls.size
    position = @recorder.calls.first
    assert_in_delta 10.0,   position[:quantity].to_f, 0.000001
    assert_in_delta 2000.0, position[:amount].to_f,   0.01
    assert_in_delta 150.0,  position[:cost_basis].to_f, 0.01
    # The open lot keeps identifying the row, even though the closed lot's id
    # sorts first.
    assert_equal "simplefin_lot-b-open", position[:external_id]
  end

  test "a sold SimpleFIN position stops showing as a current holding" do
    family = families(:dylan_family)
    item = SimplefinItem.create!(family: family, name: "Brokerage", access_url: "https://example.com/access")
    sfa = SimplefinAccount.create!(
      simplefin_item: item, account_id: "ACT-brokerage", name: "Individual", currency: "USD",
      current_balance: 5000, account_type: "investment",
      raw_holdings_payload: [
        { "id" => "HOL-aapl", "symbol" => "AAPL", "shares" => "10", "market_value" => "2000.00", "currency" => "USD" }
      ]
    )
    account = Account.create!(
      family: family, name: "Individual", currency: "USD", balance: 5000, cash_balance: 3000,
      accountable: Investment.create!
    )
    AccountProvider.create!(account: account, provider: sfa)
    security = securities(:aapl)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(sfa.reload)
    processor.stubs(:resolve_security).returns(security)

    travel_to Date.new(2026, 7, 15) do
      processor.process
    end
    assert_equal [ 10 ], account.reload.current_holdings.map { |h| h.qty.to_i }

    # The position is sold; SimpleFIN now reports the same holding at zero.
    sfa.update!(raw_holdings_payload: [
      { "id" => "HOL-aapl", "symbol" => "AAPL", "shares" => "0.00", "market_value" => "0.00", "currency" => "USD" }
    ])
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(sfa.reload)
    processor.stubs(:resolve_security).returns(security)

    travel_to Date.new(2026, 9, 25) do
      processor.process
    end

    account.reload
    assert_equal Date.new(2026, 9, 25), account.latest_provider_holdings_snapshot_date,
      "the zero report must advance the provider snapshot past the old position"
    closed = account.holdings.find_by!(date: Date.new(2026, 9, 25), security: security)
    assert_equal 0, closed.qty
    assert_equal 0, closed.amount
    assert_empty account.current_holdings
  end

  private
    def build_recording_processor(payload)
      processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)
      processor.stubs(:holdings_data).returns(payload)
      processor.stubs(:account).returns(accounts(:investment))
      processor.stubs(:resolve_security).returns(securities(:aapl))
      processor.stubs(:institution_reports_total_basis?).returns(false)
      processor.stubs(:simplefin_account).returns(
        stub(id: "sfa-test", name: "Test Investment Account", account_provider: nil)
      )

      @recorder = Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def import_holding(**kwargs)
          @calls << kwargs
          Struct.new(:id, :security_id, :qty, :amount, :currency, :date, :external_id)
                .new("h", kwargs[:security].id, kwargs[:quantity], kwargs[:amount],
                     kwargs[:currency], kwargs[:date], kwargs[:external_id])
        end
      end.new

      processor.stubs(:import_adapter).returns(@recorder)
      processor
    end
end
