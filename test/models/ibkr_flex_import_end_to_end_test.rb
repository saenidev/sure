require "test_helper"

# Regression: a realistic IBKR Flex statement (yyyyMMdd dates, levelOfDetail
# attributes, no optional ChangeInPositionValues section) must produce a correct
# total balance so imported holdings stay visible. When the balance collapsed to
# cash-only, Account#all_cash_portfolio? hid every imported holding from the
# holdings page and portfolio-wide aggregations.
class IbkrFlexImportEndToEndTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items, :ibkr_accounts, :accounts, :securities

  REALISTIC_XML = <<~XML
    <FlexQueryResponse queryName="Sure" type="AF">
      <FlexStatements count="1">
        <FlexStatement accountId="U1234567" fromDate="20250601" toDate="20260608" period="LastYear" whenGenerated="20260608;052159">
          <AccountInformation accountId="U1234567" currency="CHF" />
          <CashReport>
            <CashReportCurrency accountId="U1234567" currency="BASE_SUMMARY" fromDate="20250601" toDate="20260608" endingCash="1000.5" endingSettledCash="1000.5" levelOfDetail="BaseCurrency" />
            <CashReportCurrency accountId="U1234567" currency="CHF" fromDate="20250601" toDate="20260608" endingCash="1000.5" endingSettledCash="1000.5" levelOfDetail="Currency" />
          </CashReport>
          <EquitySummaryInBase>
            <EquitySummaryByReportDateInBase accountId="U1234567" currency="CHF" reportDate="20260605" cash="1000.5" stock="2350.5" total="3351" />
          </EquitySummaryInBase>
          <OpenPositions>
            <OpenPosition accountId="U1234567" currency="USD" fxRateToBase="0.90" assetCategory="STK" symbol="AAPL" conid="265598" reportDate="20260605" position="10" markPrice="150.00" positionValue="1500" openPrice="125.50" costBasisPrice="125.50" costBasisMoney="1255" side="Long" levelOfDetail="SUMMARY" />
          </OpenPositions>
          <Trades>
            <Trade accountId="U1234567" currency="USD" fxRateToBase="0.90" assetCategory="STK" symbol="AAPL" conid="265598" tradeID="7001" reportDate="20260601" tradeDate="20260601" transactionID="9001" buySell="BUY" quantity="2" tradePrice="140.00" tradeMoney="280" ibCommission="-1.25" ibCommissionCurrency="USD" levelOfDetail="EXECUTION" />
            <Trade accountId="U1234567" currency="USD" fxRateToBase="0.92" assetCategory="STK" symbol="AAPL" conid="265598" tradeID="7002" reportDate="20260603" tradeDate="20260603" transactionID="9002" buySell="SELL" quantity="-1" tradePrice="155.00" tradeMoney="-155" ibCommission="-1.10" ibCommissionCurrency="USD" levelOfDetail="EXECUTION" />
          </Trades>
          <CashTransactions>
            <CashTransaction accountId="U1234567" currency="CHF" fxRateToBase="1" type="Deposits/Withdrawals" amount="500" transactionID="8001" reportDate="20260602" levelOfDetail="DETAIL" />
            <CashTransaction accountId="U1234567" currency="USD" fxRateToBase="0.91" type="Dividends" amount="2.5" conid="265598" symbol="AAPL" transactionID="8002" reportDate="20260604" levelOfDetail="DETAIL" />
          </CashTransactions>
        </FlexStatement>
      </FlexStatements>
    </FlexQueryResponse>
  XML

  test "imported holdings stay visible when flex statement has no ChangeInPositionValues section" do
    parsed = IbkrItem::ReportParser.new(REALISTIC_XML).parse
    account_data = parsed[:accounts].first

    assert_equal BigDecimal("3351"), account_data[:current_balance]
    assert_equal BigDecimal("1000.5"), account_data[:cash_balance]

    ibkr_account = ibkr_accounts(:main_account)
    account = ibkr_account.ibkr_item.family.accounts.create!(
      name: "IBKR Investment",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    ibkr_account.ensure_account_provider!(account)
    ibkr_account.upsert_from_ibkr_statement!(account_data)

    result = IbkrAccount::Processor.new(ibkr_account).process

    assert_equal({ holdings: 1, trades: 2, transactions: 4 }, result)

    account.reload
    assert_equal BigDecimal("3351"), account.balance
    assert_equal BigDecimal("1000.5"), account.cash_balance
    assert_not account.all_cash_portfolio?

    assert_equal 2, account.entries.where(entryable_type: "Trade").count
    assert_equal 4, account.entries.where(entryable_type: "Transaction").count

    visible = account.current_holdings
    assert_equal 1, visible.count
    assert_equal "AAPL", visible.first.security.ticker
    assert_equal 10, visible.first.qty
  end
end
