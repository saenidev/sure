require "test_helper"

class IbkrItemReportParserTest < ActiveSupport::TestCase
  test "parses accounts, balances, and positions from flex xml" do
    parsed = IbkrItem::ReportParser.new(file_fixture("ibkr/flex_statement.xml").read).parse

    assert_equal "Sure Test", parsed[:metadata]["query_name"]
    assert_equal 2, parsed[:accounts].size

    first_account = parsed[:accounts].first
    assert_equal "U1234567", first_account[:ibkr_account_id]
    assert_equal "CHF", first_account[:currency]
    assert_equal BigDecimal("1000.50"), first_account[:cash_balance]
    assert_equal BigDecimal("3351.00"), first_account[:current_balance]
    assert_equal 2, first_account[:equity_summary_in_base].size
    assert_equal 1, first_account[:open_positions].size
    assert_equal 2, first_account[:trades].size
    assert_equal 2, first_account[:cash_transactions].size

    second_account = parsed[:accounts].second
    assert_equal "U7654321", second_account[:ibkr_account_id]
    assert_equal BigDecimal("250"), second_account[:cash_balance]
    assert_equal BigDecimal("250"), second_account[:current_balance]
    assert_equal 1, second_account[:equity_summary_in_base].size
  end

  test "parses rows when flex sections are nested in wrapper nodes" do
    xml = <<~XML
      <FlexQueryResponse queryName="Sure Test">
        <FlexStatement accountId="U1234567" toDate="2026-05-08">
          <AccountInformation currency="CHF" />
          <StatementOfFunds>
            <CashReport>
              <CashReportCurrency currency="BASE_SUMMARY" endingCash="1000.50" />
            </CashReport>
          </StatementOfFunds>
          <Positions>
            <OpenPositions>
              <OpenPosition assetCategory="STK" symbol="AAPL" position="10" markPrice="150.00" currency="USD" />
            </OpenPositions>
          </Positions>
          <Activity>
            <Trades>
              <Trade assetCategory="STK" tradeID="1001" symbol="AAPL" quantity="2" tradePrice="140.00" currency="USD" buySell="BUY" tradeDate="2026-05-08" />
            </Trades>
          </Activity>
        </FlexStatement>
      </FlexQueryResponse>
    XML

    account = IbkrItem::ReportParser.new(xml).parse[:accounts].first

    assert_equal BigDecimal("1000.50"), account[:cash_balance]
    assert_equal 1, account[:open_positions].size
    assert_equal "AAPL", account[:open_positions].first["symbol"]
    assert_equal 1, account[:trades].size
    assert_equal "1001", account[:trades].first["trade_id"]
  end

  test "derives total balance from equity summary when ChangeInPositionValues is missing" do
    xml = <<~XML
      <FlexQueryResponse queryName="Sure Test">
        <FlexStatement accountId="U1234567" fromDate="20250601" toDate="20260608">
          <AccountInformation accountId="U1234567" currency="CHF" />
          <CashReport>
            <CashReportCurrency currency="BASE_SUMMARY" endingCash="1000.50" />
          </CashReport>
          <EquitySummaryInBase>
            <EquitySummaryByReportDateInBase currency="CHF" reportDate="20260604" cash="900.50" stock="2300.50" total="3201.00" />
            <EquitySummaryByReportDateInBase currency="CHF" reportDate="20260605" cash="1000.50" stock="2350.50" total="3351.00" />
          </EquitySummaryInBase>
          <OpenPositions>
            <OpenPosition assetCategory="STK" symbol="AAPL" conid="265598" reportDate="20260605" position="10" markPrice="150.00" positionValue="1500" currency="USD" fxRateToBase="0.90" side="Long" levelOfDetail="SUMMARY" />
          </OpenPositions>
        </FlexStatement>
      </FlexQueryResponse>
    XML

    account = IbkrItem::ReportParser.new(xml).parse[:accounts].first

    assert_equal BigDecimal("1000.50"), account[:cash_balance]
    assert_equal BigDecimal("3351.00"), account[:current_balance]
  end

  test "derives total balance from open positions when equity summary is also missing" do
    xml = <<~XML
      <FlexQueryResponse queryName="Sure Test">
        <FlexStatement accountId="U1234567" fromDate="20250601" toDate="20260608">
          <AccountInformation accountId="U1234567" currency="CHF" />
          <CashReport>
            <CashReportCurrency currency="BASE_SUMMARY" endingCash="1000.50" />
          </CashReport>
          <OpenPositions>
            <OpenPosition assetCategory="STK" symbol="AAPL" conid="265598" position="10" markPrice="150.00" positionValue="1500" currency="USD" fxRateToBase="0.90" side="Long" levelOfDetail="SUMMARY" />
            <OpenPosition assetCategory="STK" symbol="NESN" conid="111111" position="2" markPrice="100.00" currency="CHF" side="Long" levelOfDetail="SUMMARY" />
          </OpenPositions>
        </FlexStatement>
      </FlexQueryResponse>
    XML

    account = IbkrItem::ReportParser.new(xml).parse[:accounts].first

    # 1500 USD * 0.90 fx + (2 * 100 CHF, no positionValue attribute) + 1000.50 cash
    assert_equal BigDecimal("2550.50"), account[:current_balance]
  end

  test "open position balance fallback only sums summary rows when lot rows are also present" do
    xml = <<~XML
      <FlexQueryResponse queryName="Sure Test">
        <FlexStatement accountId="U1234567" fromDate="20250601" toDate="20260608">
          <AccountInformation accountId="U1234567" currency="CHF" />
          <CashReport>
            <CashReportCurrency currency="BASE_SUMMARY" endingCash="1000.50" />
          </CashReport>
          <OpenPositions>
            <OpenPosition assetCategory="STK" symbol="AAPL" conid="265598" position="10" markPrice="150.00" positionValue="1500" currency="USD" fxRateToBase="0.90" side="Long" levelOfDetail="SUMMARY" />
            <OpenPosition assetCategory="STK" symbol="AAPL" conid="265598" position="4" markPrice="150.00" positionValue="600" currency="USD" fxRateToBase="0.90" side="Long" levelOfDetail="LOT" />
            <OpenPosition assetCategory="STK" symbol="AAPL" conid="265598" position="6" markPrice="150.00" positionValue="900" currency="USD" fxRateToBase="0.90" side="Long" levelOfDetail="LOT" />
          </OpenPositions>
        </FlexStatement>
      </FlexQueryResponse>
    XML

    account = IbkrItem::ReportParser.new(xml).parse[:accounts].first

    # Only the SUMMARY row counts: 1500 USD * 0.90 fx + 1000.50 cash
    assert_equal BigDecimal("2350.50"), account[:current_balance]
  end

  test "total balance stays cash only when no position data is available" do
    xml = <<~XML
      <FlexQueryResponse queryName="Sure Test">
        <FlexStatement accountId="U1234567" fromDate="20250601" toDate="20260608">
          <AccountInformation accountId="U1234567" currency="CHF" />
          <CashReport>
            <CashReportCurrency currency="BASE_SUMMARY" endingCash="250.00" />
          </CashReport>
        </FlexStatement>
      </FlexQueryResponse>
    XML

    account = IbkrItem::ReportParser.new(xml).parse[:accounts].first

    assert_equal BigDecimal("250.00"), account[:current_balance]
  end

  test "raises parse error for malformed xml" do
    error = assert_raises(IbkrItem::ReportParser::ParseError) do
      IbkrItem::ReportParser.new("<FlexQueryResponse><FlexStatement>").parse
    end

    assert_match "Invalid IBKR Flex XML", error.message
  end

  test "raises parse error when flex statements are missing" do
    error = assert_raises(IbkrItem::ReportParser::ParseError) do
      IbkrItem::ReportParser.new('<FlexQueryResponse queryName="Sure Test" />').parse
    end

    assert_equal "Invalid IBKR Flex XML: no FlexStatement nodes found.", error.message
  end

  test "raises parse error when flex statement account id is missing" do
    xml = <<~XML
      <FlexQueryResponse queryName="Sure Test">
        <FlexStatement>
          <AccountInformation currency="CHF" />
        </FlexStatement>
      </FlexQueryResponse>
    XML

    error = assert_raises(IbkrItem::ReportParser::ParseError) do
      IbkrItem::ReportParser.new(xml).parse
    end

    assert_equal "Invalid IBKR Flex XML: missing account identifier in FlexStatement.", error.message
  end
end
