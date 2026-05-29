require "test_helper"
require "ostruct"

class Forecast::DebtProjectionAdapterTest < ActiveSupport::TestCase
  test "falls back to account-balance-only rows with explicit risk flags" do
    family = families(:dylan_family)
    user = users(:family_admin)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    assert rows.any? { |row| row.fetch(:source) == "account_balance_only" && row.fetch(:risk_flags).any? { |flag| flag["type"] == "debt_projection_incomplete" } }
  end

  test "terms-ready debts with disabled auto accrual remain incomplete instead of projecting interest" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: false,
      rate_type: "fixed",
      accrual_cadence: "daily",
      minimum_payment_amount: 100,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 12, starts_on: Date.current)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal "account_balance_only", row.fetch(:source)
    assert_equal 0.to_d, row.fetch(:projected_interest)
    assert row.fetch(:risk_flags).any? { |flag| flag["reason"] == "auto_accrual_disabled" }
  end

  test "monthly debt interest projection stops at the accrual schedule period end" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    period_start = Date.current.next_month.beginning_of_month
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "monthly",
      statement_closing_day: 15,
      minimum_payment_amount: 0,
      effective_start_on: period_start
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: period_start)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: period_start, end_date: period_start.end_of_month, precision: "monthly")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal period_start.change(day: 15).iso8601, row.fetch(:source_snapshot).fetch("projected_interest").fetch("period_end_on")
  end

  test "current month debt readiness uses run date when period starts before today" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: Date.current)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal "debt_profile_snapshot", row.fetch(:source)
    assert row.fetch(:projected_interest).positive?
    assert_empty row.fetch(:risk_flags).select { |flag| flag["type"] == "debt_projection_incomplete" }
  end

  test "future rate period transitions debt from incomplete to modeled" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(interest_rate: nil)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    rate_start = Date.current.next_month.beginning_of_month
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: rate_start)
    periods = [
      Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed"),
      Forecast::PeriodBuilder::PeriodWindow.new(index: 1, start_date: rate_start, end_date: rate_start.end_of_month, precision: "monthly")
    ]

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: periods,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    account_rows = rows.select { |projection| projection.fetch(:account_id) == account.id }
    assert_equal "account_balance_only", account_rows.first.fetch(:source)
    assert_equal "debt_profile_snapshot", account_rows.second.fetch(:source)
  end

  test "future rate period does not accrue before rate start" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(interest_rate: nil)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    rate_start = 10.days.from_now.to_date
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: rate_start)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: rate_start.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal rate_start.iso8601, row.fetch(:source_snapshot).fetch("projected_interest").fetch("period_start_on")
  end

  test "required payment uses remaining obligation amount after paid amount" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    account.debt_obligations.create!(
      debt_profile: profile,
      status: "partially_paid",
      due_on: Date.current,
      currency: account.currency,
      minimum_payment_amount: 500,
      paid_amount: 200
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 300.to_d, row.fetch(:cash_payment_gap)
  end

  test "debt obligation FX uses obligation due date" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    due_on = Date.current + 3.days
    account.debt_obligations.create!(
      debt_profile: profile,
      status: "open",
      due_on: due_on,
      currency: "EUR",
      minimum_payment_amount: 100,
      paid_amount: 0
    )
    # Window must cover the obligation's due date regardless of where in the month
    # "today" falls; otherwise this breaks near month-end when due_on (today + 3
    # days) crosses into the next month and the obligation falls out of window.
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: [ Date.current.end_of_month, due_on ].max, precision: "daily_backed")
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: due_on, cache: false)
      .returns(OpenStruct.new(rate: 2.to_d, date: due_on))

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    obligation_snapshot = row.fetch(:source_snapshot).fetch("required_payment").first
    assert_equal 200.to_d, row.fetch(:cash_payment_gap)
    assert_equal due_on.iso8601, obligation_snapshot.fetch("money").fetch("exchange_rate_date")
  end

  test "overdue obligations before the forecast period are included in the first cash gap" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    account.debt_obligations.create!(
      debt_profile: profile,
      status: "overdue",
      due_on: 1.month.ago.to_date,
      currency: account.currency,
      minimum_payment_amount: 250,
      paid_amount: 0
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 250.to_d, row.fetch(:cash_payment_gap)
  end

  test "known obligations create cash gaps even when interest projection is incomplete" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: false,
      minimum_payment_amount: 300,
      effective_start_on: Date.current
    )
    account.debt_obligations.create!(
      debt_profile: profile,
      status: "open",
      due_on: Date.current,
      currency: account.currency,
      minimum_payment_amount: 300,
      paid_amount: 0
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal "account_balance_only", row.fetch(:source)
    assert_equal 300.to_d, row.fetch(:cash_payment_gap)
    assert row.fetch(:risk_flags).any? { |flag| flag["type"] == "debt_projection_incomplete" }
  end

  test "account-balance-only rows use fixed payment terms when obligations are missing" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.loan.update!(interest_rate: nil)
    account.debt_profile&.destroy!
    DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 300,
      effective_start_on: Date.current
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal "account_balance_only", row.fetch(:source)
    assert_equal 300.to_d, row.fetch(:cash_payment_gap)
    assert_equal "fixed_minimum_payment", row.fetch(:source_snapshot).fetch("required_payment").fetch("selected_source")
  end

  test "unmodeled cross-currency recurring debt transfer does not fulfill debt obligation" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: false,
      minimum_payment_amount: 300,
      effective_start_on: Date.current
    )
    account.debt_obligations.create!(
      debt_profile: profile,
      status: "open",
      due_on: Date.current,
      currency: account.currency,
      minimum_payment_amount: 300,
      paid_amount: 0
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")
    recurring_items = [
      {
        destination_account_id: account.id,
        transaction_kind: "loan_payment",
        amount: 300.to_d,
        date: Date.current,
        recurring_payment_modeled: false
      }
    ]

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: recurring_items,
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 300.to_d, row.fetch(:cash_payment_gap)
    assert_equal "0.0", row.fetch(:source_snapshot).fetch("recurring_payment_fulfilled")
  end

  test "voided allocations do not reduce remaining obligation payment" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    obligation = account.debt_obligations.create!(
      debt_profile: profile,
      status: "partially_paid",
      due_on: Date.current,
      currency: account.currency,
      minimum_payment_amount: 500,
      paid_amount: 200
    )
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: -200, account: account)
    DebtPaymentAllocation.create!(
      account: account,
      entry: entry,
      debt_profile: profile,
      debt_obligation: obligation,
      allocation_method: "manual",
      status: "voided",
      principal_amount: 200,
      currency: account.currency
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 500.to_d, row.fetch(:cash_payment_gap)
  end

  test "pending allocations do not reduce remaining obligation payment" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    obligation = account.debt_obligations.create!(
      debt_profile: profile,
      status: "partially_paid",
      due_on: Date.current,
      currency: account.currency,
      minimum_payment_amount: 500,
      paid_amount: 0
    )
    transaction = Transaction.create!(kind: "loan_payment", extra: { "simplefin" => { "pending" => true } })
    entry = Entry.create!(account: account, entryable: transaction, name: "Pending loan payment", date: Date.current, amount: -200, currency: account.currency)
    DebtPaymentAllocation.create!(
      account: account,
      entry: entry,
      debt_profile: profile,
      debt_obligation: obligation,
      allocation_method: "manual",
      status: "allocated",
      principal_amount: 200,
      currency: account.currency
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 500.to_d, row.fetch(:cash_payment_gap)
  end

  test "future-dated allocations do not reduce remaining obligation payment" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    obligation = account.debt_obligations.create!(
      debt_profile: profile,
      status: "paid",
      due_on: Date.current,
      currency: account.currency,
      minimum_payment_amount: 500,
      paid_amount: 500
    )
    transaction = Transaction.create!(kind: "loan_payment")
    entry = Entry.create!(account: account, entryable: transaction, name: "Future loan payment", date: 5.days.from_now.to_date, amount: -500, currency: account.currency)
    DebtPaymentAllocation.create!(
      account: account,
      entry: entry,
      debt_profile: profile,
      debt_obligation: obligation,
      allocation_method: "manual",
      status: "allocated",
      principal_amount: 500,
      currency: account.currency
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 500.to_d, row.fetch(:cash_payment_gap)
  end

  test "required payment fallback uses percent minimum payment when larger than fixed terms" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 100,
      minimum_payment_percent: 5,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current.next_month.beginning_of_month, end_date: Date.current.next_month.end_of_month, precision: "monthly")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 500.to_d, row.fetch(:cash_payment_gap)
    assert_equal "minimum_payment_percent", row.fetch(:source_snapshot).fetch("required_payment").fetch("selected_source")
  end

  test "actual debt payment allocation FX uses allocation entry date" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    obligation = account.debt_obligations.create!(
      debt_profile: profile,
      status: "partially_paid",
      due_on: Date.current,
      currency: account.currency,
      minimum_payment_amount: 500,
      paid_amount: 0
    )
    entry_date = 5.days.ago.to_date
    entry = entries(:transaction)
    entry.update!(date: entry_date, amount: -100, account: account, currency: "EUR")
    DebtPaymentAllocation.create!(
      account: account,
      entry: entry,
      debt_profile: profile,
      debt_obligation: obligation,
      allocation_method: "manual",
      status: "allocated",
      principal_amount: 100,
      currency: "EUR"
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: entry_date.beginning_of_month, end_date: entry_date.end_of_month, precision: "daily_backed")
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: entry_date, cache: false)
      .twice
      .returns(OpenStruct.new(rate: 2.to_d, date: entry_date))

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    allocation_snapshot = row.fetch(:source_snapshot).fetch("actual_payment_allocations").first
    assert_equal entry_date.iso8601, allocation_snapshot.fetch("money").fetch("exchange_rate_date")
  end

  test "cross-currency obligation allocations are converted before remaining payment is calculated" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: Date.current)
    obligation = account.debt_obligations.create!(
      debt_profile: profile,
      status: "partially_paid",
      due_on: Date.current,
      currency: account.currency,
      minimum_payment_amount: 500,
      paid_amount: 0
    )
    entry = entries(:transaction)
    entry.update!(date: Date.current, amount: -100, account: account, currency: "EUR")
    DebtPaymentAllocation.create!(
      account: account,
      entry: entry,
      debt_profile: profile,
      debt_obligation: obligation,
      allocation_method: "manual",
      status: "allocated",
      principal_amount: 100,
      currency: "EUR"
    )
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: account.currency, date: Date.current, cache: false)
      .twice
      .returns(OpenStruct.new(rate: 2.to_d, date: Date.current))
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 300.to_d, row.fetch(:cash_payment_gap)
    assert_equal "200.0", row.fetch(:source_snapshot).fetch("required_payment").first.fetch("paid_amount")
  end

  test "federal subsidized in-school loans do not project interest" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(subtype: "student")
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "subsidized",
      school_status: "in_school",
      principal_balance: 10_000,
      accrued_interest_balance: 0,
      capitalized_interest_total: 0
    )
    profile.save!
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 6, starts_on: Date.current)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 0.to_d, row.fetch(:projected_interest)
  end

  test "federal projected interest converts native account currency into family currency" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000, currency: "EUR")
    account.loan.update!(subtype: "student")
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "unsubsidized",
      school_status: "repayment",
      principal_balance: 10_000,
      accrued_interest_balance: 0,
      capitalized_interest_total: 0
    )
    profile.save!
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365.25, starts_on: Date.current)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current, precision: "daily_backed")
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: Date.current, cache: false)
      .twice
      .returns(OpenStruct.new(rate: 2.to_d, date: Date.current))

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    assert_equal 200.to_d, row.fetch(:projected_interest)
    assert_equal "EUR", row.fetch(:source_snapshot).fetch("projected_interest").fetch("native_currency")
  end

  test "non federal foreign currency projected interest snapshots native basis" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000, currency: "EUR")
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: Date.current)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current, precision: "daily_backed")
    ExchangeRate.expects(:find_or_fetch_rate)
      .with(from: "EUR", to: family.currency, date: Date.current, cache: false)
      .twice
      .returns(OpenStruct.new(rate: 2.to_d, date: Date.current))

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    row = rows.find { |projection| projection.fetch(:account_id) == account.id }
    snapshot = row.fetch(:source_snapshot).fetch("projected_interest")
    assert_equal 200.to_d, row.fetch(:projected_interest)
    assert_equal "EUR", snapshot.fetch("native_currency")
    assert_equal "10000.0", snapshot.fetch("native_opening_balance")
    assert_equal Date.current.iso8601, snapshot.fetch("exchange_rate_date")
  end

  test "projected interest uses carried forecast balance after projected payments" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 1000)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: Date.current)
    periods = [
      Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current, precision: "daily_backed"),
      Forecast::PeriodBuilder::PeriodWindow.new(index: 1, start_date: Date.current + 1.day, end_date: Date.current + 1.day, precision: "daily_backed")
    ]
    recurring_items = [
      {
        destination_account_id: account.id,
        transaction_kind: "loan_payment",
        amount: 500.to_d,
        date: Date.current
      }
    ]

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: periods,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: recurring_items,
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    first_row = rows.find { |projection| projection.fetch(:account_id) == account.id && projection.fetch(:period_start_on) == periods.first.start_date }
    second_row = rows.find { |projection| projection.fetch(:account_id) == account.id && projection.fetch(:period_start_on) == periods.second.start_date }
    assert_equal first_row.fetch(:ending_balance), second_row.fetch(:opening_balance)
    assert_operator second_row.fetch(:projected_interest), :<, first_row.fetch(:projected_interest)
    assert_in_delta 5.1, second_row.fetch(:projected_interest).to_f, 0.01
  end

  test "mixed federal interest-bearing basis carries forward after projected principal payments" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 1000)
    account.loan.update!(subtype: "student")
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    profile.federal_student_loan.assign(
      enabled: true,
      subsidy_type: "mixed",
      school_status: "deferment",
      principal_balance: 1000,
      interest_bearing_principal_balance: 400,
      accrued_interest_balance: 0,
      capitalized_interest_total: 0
    )
    profile.save!
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365.25, starts_on: Date.current)
    periods = [
      Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current, precision: "daily_backed"),
      Forecast::PeriodBuilder::PeriodWindow.new(index: 1, start_date: Date.current + 1.day, end_date: Date.current + 1.day, precision: "daily_backed")
    ]
    recurring_items = [
      {
        destination_account_id: account.id,
        transaction_kind: "loan_payment",
        amount: 200.to_d,
        date: Date.current
      }
    ]

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: periods,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: recurring_items,
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call

    second_row = rows.find { |projection| projection.fetch(:account_id) == account.id && projection.fetch(:period_start_on) == periods.second.start_date }
    assert_in_delta 2.04, second_row.fetch(:projected_interest).to_f, 0.001
    assert_equal "204.0", second_row.fetch(:source_snapshot).fetch("projected_interest").fetch("carried_native_interest_bearing_principal_balance")
  end

  test "forecast debt drawdowns feed later debt interest math" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 1000)
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: Date.current)
    periods = [
      Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current, precision: "daily_backed"),
      Forecast::PeriodBuilder::PeriodWindow.new(index: 1, start_date: Date.current + 1.day, end_date: Date.current + 1.day, precision: "daily_backed")
    ]

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: periods,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      forecast_debt_events: [
        {
          account_id: account.id,
          effect_type: "debt_drawdown",
          transaction_kind: "standard",
          date: Date.current,
          debt_delta: 500.to_d,
          risk_flags: [],
          source_snapshot: { "id" => "drawdown" }
        }
      ]
    ).call

    first_row = rows.find { |projection| projection.fetch(:account_id) == account.id && projection.fetch(:period_start_on) == periods.first.start_date }
    second_row = rows.find { |projection| projection.fetch(:account_id) == account.id && projection.fetch(:period_start_on) == periods.second.start_date }
    assert_equal 500.to_d, first_row.fetch(:projected_drawdown)
    assert_operator second_row.fetch(:projected_interest), :>, 10.to_d
  end

  test "explicit past run date produces identical rows regardless of wall clock" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    start_on = Date.current - 200.days
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 100,
      effective_start_on: start_on
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: start_on)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: start_on, end_date: start_on.end_of_month, precision: "daily_backed")

    build_rows = lambda do
      Forecast::DebtProjectionAdapter.new(
        family: family,
        user: user,
        periods: [ period ],
        money_converter: Forecast::MoneyConverter.new(family: family, as_of: start_on),
        recurring_items: [],
        included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
        run_date: start_on
      ).call.find { |projection| projection.fetch(:account_id) == account.id }
    end

    first = build_rows.call
    second = nil
    travel_to(Date.current + 45.days) { second = build_rows.call }

    assert_equal "debt_profile_snapshot", first.fetch(:source)
    %i[projected_interest projected_payment ending_balance cash_payment_gap].each do |key|
      assert_equal first.fetch(key), second.fetch(key), "expected #{key} to be deterministic across wall clocks"
    end
  end

  test "run date earlier than rate period start clamps interest accrual start to period start" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(interest_rate: nil)
    run_date = Date.current - 200.days
    rate_start = run_date + 10.days
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: run_date
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: rate_start)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: run_date, end_date: rate_start.end_of_month, precision: "daily_backed")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: run_date),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: run_date
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    assert_equal rate_start.iso8601, row.fetch(:source_snapshot).fetch("projected_interest").fetch("period_start_on")
  end

  test "allocation dated after run date but before wall clock is excluded from paid amount" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    run_date = Date.current - 200.days
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 500,
      effective_start_on: run_date
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: run_date)
    obligation = account.debt_obligations.create!(
      debt_profile: profile,
      status: "partially_paid",
      due_on: run_date,
      currency: account.currency,
      minimum_payment_amount: 500,
      paid_amount: 0
    )
    # Entry dated after run_date but well before the wall clock (Date.current).
    # The cutoff must use run_date, so this allocation should NOT reduce the gap.
    allocation_date = run_date + 10.days
    transaction = Transaction.create!(kind: "loan_payment")
    entry = Entry.create!(account: account, entryable: transaction, name: "Post-run-date payment", date: allocation_date, amount: -200, currency: account.currency)
    DebtPaymentAllocation.create!(
      account: account,
      entry: entry,
      debt_profile: profile,
      debt_obligation: obligation,
      allocation_method: "manual",
      status: "allocated",
      principal_amount: 200,
      currency: account.currency
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: run_date, end_date: allocation_date.end_of_month, precision: "daily_backed")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: run_date),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: run_date
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    assert_equal 500.to_d, row.fetch(:cash_payment_gap)
  end

  test "run date defaults to money converter as_of for backward compatibility" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    start_on = Date.current - 200.days
    account.debt_profile&.destroy!
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 100,
      effective_start_on: start_on
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: start_on)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: start_on, end_date: start_on.end_of_month, precision: "daily_backed")
    converter = Forecast::MoneyConverter.new(family: family, as_of: start_on)

    explicit = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: converter,
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: start_on
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    defaulted = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: converter,
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    %i[projected_interest projected_payment ending_balance cash_payment_gap].each do |key|
      assert_equal explicit.fetch(key), defaulted.fetch(key), "expected #{key} default to match explicit run_date"
    end
  end

  test "fixed payment paying off mid-horizon stamps a single payoff period" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 1000)
    account.debt_profile&.destroy!
    start_on = Date.current.next_month.beginning_of_month
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "monthly",
      minimum_payment_amount: 400,
      effective_start_on: start_on
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: start_on)
    periods = (0..4).map do |index|
      month = start_on + index.months
      Forecast::PeriodBuilder::PeriodWindow.new(index: index, start_date: month.beginning_of_month, end_date: month.end_of_month, precision: "monthly")
    end

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: periods,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: Date.current
    ).call.select { |projection| projection.fetch(:account_id) == account.id }

    payoff_rows = rows.select { |row| row.fetch(:is_payoff_period) }
    assert_equal 1, payoff_rows.size
    payoff_row = payoff_rows.first
    # 1000 / 400 per month -> third month (index 2) zeroes the balance.
    assert_equal periods.third.end_date, payoff_row.fetch(:period_end_on)
    assert_equal 0.to_d, payoff_row.fetch(:ending_balance)
    assert_equal periods.third.end_date, payoff_row.fetch(:payoff_projected_on)
    assert_equal periods.third.end_date.iso8601, payoff_row.fetch(:source_snapshot).fetch("payoff_projected_on")
    assert payoff_row.fetch(:source_snapshot).fetch("is_payoff_period")

    later_rows = rows.select { |row| row.fetch(:period_end_on) > payoff_row.fetch(:period_end_on) }
    assert later_rows.any?
    later_rows.each do |row|
      assert_equal 0.to_d, row.fetch(:ending_balance)
      refute row.fetch(:is_payoff_period)
      assert_equal periods.third.end_date, row.fetch(:payoff_projected_on)
    end
  end

  test "zero-interest fixed payment amortizes on ceil(balance/payment) schedule" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 1000)
    account.debt_profile&.destroy!
    start_on = Date.current.next_month.beginning_of_month
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "monthly",
      minimum_payment_amount: 300,
      effective_start_on: start_on
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: start_on)
    periods = (0..5).map do |index|
      month = start_on + index.months
      Forecast::PeriodBuilder::PeriodWindow.new(index: index, start_date: month.beginning_of_month, end_date: month.end_of_month, precision: "monthly")
    end

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: periods,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: Date.current
    ).call.select { |projection| projection.fetch(:account_id) == account.id }

    # ceil(1000 / 300) = 4 payments -> payoff in the 4th month (index 3).
    expected_payoff_index = (1000.0 / 300).ceil - 1
    payoff_row = rows.find { |row| row.fetch(:is_payoff_period) }
    assert_equal periods[expected_payoff_index].end_date, payoff_row.fetch(:period_end_on)
    # Every pre-payoff row amortizes (ending < opening) with zero interest.
    rows.take(expected_payoff_index).each do |row|
      assert_equal 0.to_d, row.fetch(:projected_interest)
      assert_equal "amortizing", row.fetch(:balance_trend)
    end
  end

  test "interest exceeding payment grows the balance and flags it without projecting payoff" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.debt_profile&.destroy!
    start_on = Date.current.next_month.beginning_of_month
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "monthly",
      minimum_payment_amount: 1,
      effective_start_on: start_on
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: start_on)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: start_on.beginning_of_month, end_date: start_on.end_of_month, precision: "monthly")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: Date.current
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    assert_operator row.fetch(:projected_interest), :>, row.fetch(:projected_payment)
    assert_equal "growing", row.fetch(:balance_trend)
    assert_equal "growing", row.fetch(:source_snapshot).fetch("balance_trend")
    assert row.fetch(:risk_flags).any? { |flag| flag["type"] == "debt_balance_growing" }
    assert_nil row.fetch(:payoff_projected_on)
    refute row.fetch(:is_payoff_period)
    assert_nil row.fetch(:source_snapshot).fetch("payoff_projected_on")
  end

  test "balance exactly hitting zero on the final horizon period is the payoff period" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 800)
    account.debt_profile&.destroy!
    start_on = Date.current.next_month.beginning_of_month
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "monthly",
      minimum_payment_amount: 400,
      effective_start_on: start_on
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: start_on)
    periods = (0..1).map do |index|
      month = start_on + index.months
      Forecast::PeriodBuilder::PeriodWindow.new(index: index, start_date: month.beginning_of_month, end_date: month.end_of_month, precision: "monthly")
    end

    rows = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: periods,
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: Date.current
    ).call.select { |projection| projection.fetch(:account_id) == account.id }

    last_row = rows.last
    assert_equal 0.to_d, last_row.fetch(:ending_balance)
    assert last_row.fetch(:is_payoff_period)
    assert_equal last_row.fetch(:period_end_on), last_row.fetch(:payoff_projected_on)
    refute rows.first.fetch(:is_payoff_period)
    assert_equal periods.last.end_date, rows.first.fetch(:payoff_projected_on)
  end

  test "rate period changing mid-month accrues each sub-span at its own rate" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(interest_rate: nil)
    account.debt_profile&.destroy!
    month_start = Date.current.next_month.beginning_of_month
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: month_start
    )
    promo_end = month_start.change(day: 15)
    after_start = month_start.change(day: 16)
    # Promo 0% for days 1-15, 18% from day 16 to month end.
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "promotional", annual_rate: 0, starts_on: month_start, ends_on: promo_end)
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 18, starts_on: after_start)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: month_start, end_date: month_start.end_of_month, precision: "monthly")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: month_start
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    promo_days = (promo_end - month_start).to_i + 1
    after_days = (month_start.end_of_month - after_start).to_i + 1
    expected = (10_000.to_d * (18.to_d / 100) * after_days / 365).round(4)

    assert_equal expected, row.fetch(:projected_interest)

    spans = row.fetch(:source_snapshot).fetch("projected_interest").fetch("rate_spans")
    assert_equal 2, spans.size
    assert_equal month_start.iso8601, spans.first.fetch("start_on")
    assert_equal promo_end.iso8601, spans.first.fetch("end_on")
    assert_equal promo_days, spans.first.fetch("days")
    assert_equal "0.0", spans.first.fetch("interest")
    assert_equal after_start.iso8601, spans.second.fetch("start_on")
    assert_equal month_start.end_of_month.iso8601, spans.second.fetch("end_on")
    assert_equal after_days, spans.second.fetch("days")
    assert_equal expected.to_s, spans.second.fetch("interest")
  end

  test "rate period boundary exactly on period end accrues new rate only on the final day" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(interest_rate: nil)
    account.debt_profile&.destroy!
    month_start = Date.current.next_month.beginning_of_month
    month_end = month_start.end_of_month
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: month_start
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 12, starts_on: month_start, ends_on: month_end.prev_day)
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 36, starts_on: month_end)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: month_start, end_date: month_end, precision: "monthly")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: month_start
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    first_days = (month_end.prev_day - month_start).to_i + 1
    first_interest = (10_000.to_d * (12.to_d / 100) * first_days / 365).round(4)
    last_interest = (10_000.to_d * (36.to_d / 100) * 1 / 365).round(4)

    spans = row.fetch(:source_snapshot).fetch("projected_interest").fetch("rate_spans")
    assert_equal 2, spans.size
    assert_equal first_days, spans.first.fetch("days")
    assert_equal 1, spans.second.fetch("days")
    assert_equal month_end.iso8601, spans.second.fetch("start_on")
    assert_equal month_end.iso8601, spans.second.fetch("end_on")
    # No gap and no double count: spans cover exactly the full month once.
    assert_equal (month_end - month_start).to_i + 1, spans.sum { |span| span.fetch("days") }
    assert_equal (first_interest + last_interest), row.fetch(:projected_interest)
  end

  test "rate period boundary exactly on period start does not create a zero-day span" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(interest_rate: nil)
    account.debt_profile&.destroy!
    month_start = Date.current.next_month.beginning_of_month
    month_end = month_start.end_of_month
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: month_start
    )
    # Rate period begins exactly on the forecast period start.
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 24, starts_on: month_start)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: month_start, end_date: month_end, precision: "monthly")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: month_start
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    spans = row.fetch(:source_snapshot).fetch("projected_interest").fetch("rate_spans")
    assert_equal 1, spans.size
    full_days = (month_end - month_start).to_i + 1
    assert_equal full_days, spans.first.fetch("days")
  end

  test "variable rate priority overlap resolves higher priority regardless of insertion order" do
    family = families(:dylan_family)
    user = users(:family_admin)
    month_start = Date.current.next_month.beginning_of_month
    month_end = month_start.end_of_month
    mid = month_start.change(day: 16)

    build_row = lambda do |insert_high_priority_first|
      account = accounts(:loan)
      account.update!(balance: 10_000)
      account.loan.update!(interest_rate: nil)
      account.debt_profile&.destroy!
      profile = DebtProfile.create!(
        account: account,
        status: "active",
        auto_accrual_enabled: true,
        rate_type: "fixed",
        accrual_cadence: "daily",
        compounding_cadence: "daily",
        minimum_payment_amount: 0,
        effective_start_on: month_start
      )
      base = -> { DebtRatePeriod.create!(debt_profile: profile, rate_type: "variable", annual_rate: 12, starts_on: month_start, priority: 0) }
      # Higher-priority adjustment covering the back half of the month at 30%.
      high = -> { DebtRatePeriod.create!(debt_profile: profile, rate_type: "adjustable", annual_rate: 30, starts_on: mid, priority: 10) }
      if insert_high_priority_first
        high.call
        base.call
      else
        base.call
        high.call
      end
      period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: month_start, end_date: month_end, precision: "monthly")

      Forecast::DebtProjectionAdapter.new(
        family: family,
        user: user,
        periods: [ period ],
        money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
        recurring_items: [],
        included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
        run_date: month_start
      ).call.find { |projection| projection.fetch(:account_id) == account.id }
    end

    ordered = build_row.call(false)
    reordered = build_row.call(true)

    assert_equal ordered.fetch(:projected_interest), reordered.fetch(:projected_interest)
    ordered_spans = ordered.fetch(:source_snapshot).fetch("projected_interest").fetch("rate_spans")
    reordered_spans = reordered.fetch(:source_snapshot).fetch("projected_interest").fetch("rate_spans")
    assert_equal ordered_spans, reordered_spans

    assert_equal 2, ordered_spans.size
    assert_equal 12.to_d.to_s, ordered_spans.first.fetch("annual_rate")
    assert_equal 30.to_d.to_s, ordered_spans.second.fetch("annual_rate")
    first_days = (mid.prev_day - month_start).to_i + 1
    second_days = (month_end - mid).to_i + 1
    expected = (10_000.to_d * (12.to_d / 100) * first_days / 365).round(4) +
      (10_000.to_d * (30.to_d / 100) * second_days / 365).round(4)
    assert_equal expected, ordered.fetch(:projected_interest)
  end

  test "single rate spanning the whole horizon matches the single-rate computation" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(interest_rate: nil)
    account.debt_profile&.destroy!
    month_start = Date.current.next_month.beginning_of_month
    month_end = month_start.end_of_month
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: month_start
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 365, starts_on: month_start)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: month_start, end_date: month_end, precision: "monthly")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: month_start
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    days = (month_end - month_start).to_i + 1
    expected = (10_000.to_d * (365.to_d / 100) * days / 365).round(4)
    assert_equal expected, row.fetch(:projected_interest)
    spans = row.fetch(:source_snapshot).fetch("projected_interest").fetch("rate_spans")
    assert_equal 1, spans.size
    assert_equal days, spans.first.fetch("days")
    assert_equal expected.to_s, spans.first.fetch("interest")
  end

  test "zero-rate span contributes no interest while later span accrues" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.loan.update!(interest_rate: nil)
    account.debt_profile&.destroy!
    month_start = Date.current.next_month.beginning_of_month
    month_end = month_start.end_of_month
    mid = month_start.change(day: 16)
    profile = DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: true,
      rate_type: "fixed",
      accrual_cadence: "daily",
      compounding_cadence: "daily",
      minimum_payment_amount: 0,
      effective_start_on: month_start
    )
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 0, starts_on: month_start, ends_on: mid.prev_day)
    DebtRatePeriod.create!(debt_profile: profile, rate_type: "fixed", annual_rate: 24, starts_on: mid)
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: month_start, end_date: month_end, precision: "monthly")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user),
      run_date: month_start
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    spans = row.fetch(:source_snapshot).fetch("projected_interest").fetch("rate_spans")
    assert_equal 2, spans.size
    assert_equal "0.0", spans.first.fetch("interest")
    second_days = (month_end - mid).to_i + 1
    expected = (10_000.to_d * (24.to_d / 100) * second_days / 365).round(4)
    assert_equal expected, row.fetch(:projected_interest)
    assert_equal expected.to_s, spans.second.fetch("interest")
  end

  test "account-balance-only fallback rows never carry payoff or growing metadata" do
    family = families(:dylan_family)
    user = users(:family_admin)
    account = accounts(:loan)
    account.update!(balance: 10_000)
    account.debt_profile&.destroy!
    DebtProfile.create!(
      account: account,
      status: "active",
      auto_accrual_enabled: false,
      minimum_payment_amount: 0,
      effective_start_on: Date.current
    )
    period = Forecast::PeriodBuilder::PeriodWindow.new(index: 0, start_date: Date.current, end_date: Date.current.end_of_month, precision: "daily_backed")

    row = Forecast::DebtProjectionAdapter.new(
      family: family,
      user: user,
      periods: [ period ],
      money_converter: Forecast::MoneyConverter.new(family: family, as_of: Date.current),
      recurring_items: [],
      included_account_scope: Forecast::IncludedAccountScope.new(family: family, user: user)
    ).call.find { |projection| projection.fetch(:account_id) == account.id }

    assert_equal "account_balance_only", row.fetch(:source)
    refute row.key?(:payoff_projected_on)
    refute row.key?(:is_payoff_period)
    refute row.key?(:balance_trend)
    refute row.fetch(:source_snapshot).key?("payoff_projected_on")
    refute row.fetch(:source_snapshot).key?("is_payoff_period")
    refute row.fetch(:source_snapshot).key?("balance_trend")
    assert row.fetch(:risk_flags).any? { |flag| flag["type"] == "debt_projection_incomplete" }
    refute row.fetch(:risk_flags).any? { |flag| flag["type"] == "debt_balance_growing" }
  end
end
