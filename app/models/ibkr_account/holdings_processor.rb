class IbkrAccount::HoldingsProcessor
  include IbkrAccount::DataHelpers

  def initialize(ibkr_account)
    @ibkr_account = ibkr_account
  end

  def process
    return unless account.present?

    grouped_positions.each do |(_, _, report_date), group|
      process_group(group, report_date)
    end
  end

  private

    def account
      @ibkr_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def grouped_positions
      Array(@ibkr_account.raw_holdings_payload).each_with_object({}) do |position, groups|
        data = position.with_indifferent_access
        next unless supported_position?(data)

        currency = extract_currency(data, fallback: @ibkr_account.currency)
        report_date = parse_date(data[:report_date]) || @ibkr_account.report_date || Date.current
        key = [ position_identity(data), currency, report_date ]
        groups[key] ||= []
        groups[key] << data
      end
    end

    def process_group(rows, report_date)
      sample = rows.first
      security = resolve_security(sample)
      return unless security

      price = parse_decimal(sample[:mark_price])
      aggregate = aggregate_lots(rows)
      return unless price && aggregate

      quantity   = aggregate[:quantity]
      cost_basis = aggregate[:cost_basis]
      amount = quantity * price
      currency = extract_currency(sample, fallback: @ibkr_account.currency)
      external_id = [ "ibkr", @ibkr_account.ibkr_account_id, position_identity(sample), report_date, currency ].join("_")

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: report_date,
        price: price,
        cost_basis: cost_basis,
        external_id: external_id,
        source: "ibkr",
        account_provider_id: @ibkr_account.account_provider&.id,
        delete_future_holdings: false
      )
    end

    def aggregate_lots(rows)
      total_quantity = BigDecimal("0")
      total_cost = BigDecimal("0")
      missing_cost_basis = false

      rows.each do |row|
        row_quantity = position_quantity(row)
        next unless row_quantity

        total_quantity += row_quantity.abs

        row_cost_basis = parse_decimal(row[:cost_basis_price])
        if row_cost_basis
          total_cost += row_quantity.abs * row_cost_basis
        else
          missing_cost_basis = true
        end
      end

      return nil if total_quantity.zero?

      cost_basis = missing_cost_basis ? nil : total_cost / total_quantity
      { quantity: total_quantity, cost_basis: cost_basis }
    end

    def supported_position?(row)
      position = position_quantity(row)

      stock_asset_category?(row[:asset_category]) &&
        long_position?(row, position) &&
        row[:symbol].present? &&
        extract_currency(row, fallback: @ibkr_account.currency).present? &&
        position.present? &&
        row[:mark_price].present?
    end

    def long_position?(row, position)
      side = row[:side].to_s
      return side == "Long" if side.present?

      position&.positive?
    end

    def position_identity(row)
      row[:conid].presence || row[:symbol].to_s.upcase
    end

    def position_quantity(row)
      parse_decimal(row[:position]) || parse_decimal(row[:quantity])
    end
end
