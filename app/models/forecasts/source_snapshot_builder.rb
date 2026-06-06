# frozen_string_literal: true

module Forecasts
  # Forecast V2 source snapshot builder. Reads connected Sure data for a plan's
  # family (accounts/balances, recurring transactions, budgets, FX rates,
  # holdings/prices), threaded by an explicit `as_of` date, and normalizes it into
  # the engine's serializable `source_snapshot` shape.
  #
  # This is an application service (a PORO) and is allowed to read ActiveRecord —
  # it sits *outside* the pure `Forecasts::Projection::*` engine. It produces the
  # immutable, serializable inputs the engine later consumes via the plan packet;
  # the engine itself never queries models or reads `Date.current`.
  #
  # Responsibilities (see spec "Source Snapshot", "Source Snapshot Tables",
  # "Source-To-Assumption Mapping"):
  #   - Normalize family data into a deterministic, money-as-decimal-string payload.
  #   - Compute a stable `source_snapshot_hash` (order-independent).
  #   - Capture `freshness_state`, `included_account_ids`, and `issue_candidates`
  #     (recoverable source findings such as missing FX rates) before they become
  #     engine crashes.
  #   - Persist a Forecasts::SourceSnapshot row, reused by hash; only rebuild when
  #     no usable snapshot exists or the current one is stale.
  #
  # Family-scoping is anchored to the plan's family. The builder never accepts or
  # trusts a family_id from params — the only family it ever reads is `plan.family`.
  class SourceSnapshotBuilder
    SCHEMA_VERSION = "forecast-source-snapshot-v1"

    attr_reader :plan, :family, :as_of, :created_by_event

    def initialize(plan:, as_of:, created_by_event: nil)
      raise ArgumentError, "as_of is required" if as_of.nil?

      @plan = plan
      # Family scope is derived from the plan, never from caller-supplied params.
      @family = plan.family
      @as_of = as_of.to_date
      @created_by_event = created_by_event
    end

    # Returns a persisted Forecasts::SourceSnapshot. Idempotent by hash: if a
    # snapshot with the freshly computed hash already exists for this plan, it is
    # reused unchanged. Otherwise a new row is written and any prior fresh
    # snapshot for the plan is marked stale.
    def build
      computed = compute
      hash = computed[:source_snapshot_hash]

      existing = plan.forecast_source_snapshots.for_hash(hash).first
      return existing if existing

      Forecasts::SourceSnapshot.transaction do
        mark_prior_snapshots_stale!
        persist!(computed)
      end
    end

    private
      # Builds the normalized payload and its stable hash without touching the
      # database for writes. Exposed (via send) to tests asserting hash stability.
      def compute
        payload = build_payload
        {
          payload: payload,
          included_account_ids: included_account_ids,
          issue_candidates: issue_candidates,
          source_versions: source_versions,
          source_snapshot_hash: Forecasts::Projection.stable_hash(payload)
        }
      end

      def persist!(computed)
        plan.forecast_source_snapshots.create!(
          family: family,
          as_of: as_of,
          source_snapshot_hash: computed[:source_snapshot_hash],
          freshness_state: :fresh,
          included_account_ids: computed[:included_account_ids],
          source_versions: computed[:source_versions],
          issue_candidates: computed[:issue_candidates],
          snapshot_payload: computed[:payload],
          created_by_event: created_by_event,
          schema_version: SCHEMA_VERSION
        )
      end

      def mark_prior_snapshots_stale!
        plan.forecast_source_snapshots.where(freshness_state: :fresh).update_all(freshness_state: :stale)
      end

      # --- Normalized payload ---------------------------------------------------

      # The engine-consumed source_snapshot shape. Deterministic and serializable:
      # collections are sorted by stable keys, money is decimal strings, and the
      # as_of is an explicit ISO8601 instant so the pure engine never reads
      # Date.current. See spec "Source Snapshot" and "Plan Packet".
      def build_payload
        {
          schema_version: SCHEMA_VERSION,
          as_of: as_of.beginning_of_day.utc.iso8601,
          reporting_currency: reporting_currency,
          opening_balances: opening_balances,
          accounts: account_rows,
          recurring_patterns: recurring_pattern_rows,
          budgets: budget_rows,
          holdings: holding_rows,
          prices: price_rows,
          fx_rates: fx_rate_rows
        }
      end

      def reporting_currency
        @reporting_currency ||= (plan.reporting_currency.presence || family.currency || "USD")
      end

      # Aggregate opening balances in the reporting currency. Cross-currency
      # accounts are converted with an as_of FX rate when one exists; accounts
      # without a usable rate are excluded from the aggregate (they surface as
      # missing_fx_rate issue candidates instead of silently distorting totals).
      def opening_balances
        liquid = BigDecimal("0")
        debt = BigDecimal("0")
        portfolio = BigDecimal("0")

        accounts.each do |account|
          converted = converted_balance(account)
          next if converted.nil?

          if account.classification == "liability"
            debt += converted
          elsif investment_like?(account)
            portfolio += converted
          else
            liquid += converted
          end
        end

        {
          liquid_cash: decimal_string(liquid),
          debt_balance: decimal_string(debt),
          portfolio_value: decimal_string(portfolio)
        }
      end

      def account_rows
        accounts.map do |account|
          {
            id: account.id,
            name: account.name,
            classification: account.classification,
            accountable_type: account.accountable_type,
            currency: account.currency,
            balance: decimal_string(account.balance),
            cash_balance: decimal_string(account.cash_balance)
          }
        end.sort_by { |row| row[:id].to_s }
      end

      def recurring_pattern_rows
        family.recurring_transactions
          .where(status: "active")
          .map do |recurring|
            {
              id: recurring.id,
              name: recurring.name,
              account_id: recurring.account_id,
              destination_account_id: recurring.destination_account_id,
              merchant_id: recurring.merchant_id,
              amount: decimal_string(recurring.amount),
              currency: recurring.currency,
              expected_day_of_month: recurring.expected_day_of_month,
              next_expected_date: date_string(recurring.next_expected_date)
            }
          end.sort_by { |row| row[:id].to_s }
      end

      def budget_rows
        family.budgets
          .where("start_date <= ?", as_of.end_of_month)
          .order(start_date: :desc)
          .limit(12)
          .map do |budget|
            {
              id: budget.id,
              start_date: date_string(budget.start_date),
              end_date: date_string(budget.end_date),
              budgeted_spending: decimal_string(budget.budgeted_spending),
              expected_income: decimal_string(budget.expected_income),
              currency: budget.currency
            }
          end.sort_by { |row| row[:id].to_s }
      end

      # Latest holding row per (account, security) on or before as_of.
      def holding_rows
        latest_holdings.map do |holding|
          {
            id: holding.id,
            account_id: holding.account_id,
            security_id: holding.security_id,
            date: date_string(holding.date),
            qty: decimal_string(holding.qty),
            price: decimal_string(holding.price),
            amount: decimal_string(holding.amount),
            currency: holding.currency
          }
        end.sort_by { |row| row[:id].to_s }
      end

      # Security prices derived from the latest holdings (one per security).
      def price_rows
        latest_holdings
          .group_by(&:security_id)
          .map do |security_id, holdings|
            latest = holdings.max_by(&:date)
            {
              security_id: security_id,
              date: date_string(latest.date),
              price: decimal_string(latest.price),
              currency: latest.currency
            }
          end.sort_by { |row| row[:security_id].to_s }
      end

      # FX rates needed to convert every non-reporting account currency, picking
      # the freshest rate dated on or before as_of for each currency.
      def fx_rate_rows
        foreign_currencies.filter_map do |currency|
          rate = latest_fx_rate(currency)
          next if rate.nil?

          {
            from: currency,
            to: reporting_currency,
            date: date_string(rate.date),
            rate: decimal_string(rate.rate)
          }
        end.sort_by { |row| [ row[:from].to_s, row[:date].to_s ] }
      end

      # --- Issue candidates -----------------------------------------------------

      # Recoverable source findings captured before they become engine failures.
      # Currently: a missing_fx_rate candidate per non-reporting currency that has
      # no rate dated on or before as_of. See spec "Source-To-Assumption Mapping"
      # ("Missing rates create `missing_fx_rate` issues").
      def issue_candidates
        @issue_candidates ||= foreign_currencies.filter_map do |currency|
          next if latest_fx_rate(currency)

          {
            code: "missing_fx_rate",
            severity: "error",
            source: "source_snapshot",
            currency: currency,
            target_currency: reporting_currency,
            affected_entity_type: "currency",
            affected_entity_id: currency,
            message_key: "forecasts.issues.missing_fx_rate"
          }
        end.sort_by { |candidate| candidate[:currency].to_s }
      end

      # --- Freshness / versions -------------------------------------------------

      # Coarse provenance markers used to reason about snapshot freshness without
      # re-reading every row. Kept out of the hashed payload so freshness drift
      # alone does not force an engine recompute.
      def source_versions
        {
          accounts: collection_version(accounts),
          recurring_transactions: collection_version(family.recurring_transactions.to_a),
          budgets: collection_version(family.budgets.to_a),
          holdings: collection_version(latest_holdings),
          exchange_rates: collection_version(relevant_exchange_rates)
        }
      end

      def collection_version(records)
        records = Array(records)
        max_updated = records.filter_map { |record| record.try(:updated_at) }.max
        "#{records.size}-#{max_updated&.to_i || 0}"
      end

      # --- Account loading / scoping --------------------------------------------

      def accounts
        @accounts ||= family.accounts.visible.includes(:accountable).to_a
      end

      def included_account_ids
        @included_account_ids ||= accounts.map(&:id)
      end

      def investment_like?(account)
        %w[Investment Crypto].include?(account.accountable_type)
      end

      # --- Currency conversion --------------------------------------------------

      def converted_balance(account)
        balance = to_decimal(account.balance)
        return balance if account.currency == reporting_currency

        rate = latest_fx_rate(account.currency)
        return nil if rate.nil?

        balance * to_decimal(rate.rate)
      end

      def foreign_currencies
        @foreign_currencies ||= accounts
          .map(&:currency)
          .compact
          .uniq
          .reject { |currency| currency == reporting_currency }
          .sort
      end

      # Freshest rate from `currency` to the reporting currency dated on or before
      # as_of. Memoized per currency; nil when no applicable rate exists.
      def latest_fx_rate(currency)
        @fx_rate_cache ||= {}
        return @fx_rate_cache[currency] if @fx_rate_cache.key?(currency)

        @fx_rate_cache[currency] = ExchangeRate
          .where(from_currency: currency, to_currency: reporting_currency)
          .where("date <= ?", as_of)
          .order(date: :desc)
          .first
      end

      def relevant_exchange_rates
        foreign_currencies.filter_map { |currency| latest_fx_rate(currency) }
      end

      # --- Holdings -------------------------------------------------------------

      def latest_holdings
        @latest_holdings ||= begin
          rows = Holding
            .where(account_id: included_account_ids)
            .where("date <= ?", as_of)
            .order(date: :desc)
            .to_a

          rows
            .group_by { |holding| [ holding.account_id, holding.security_id, holding.currency ] }
            .map { |_key, group| group.max_by(&:date) }
        end
      end

      # --- Serialization helpers ------------------------------------------------

      def decimal_string(value)
        to_decimal(value).to_s("F")
      end

      def to_decimal(value)
        return BigDecimal("0") if value.nil? || value == ""
        return value if value.is_a?(BigDecimal)

        BigDecimal(value.to_s)
      end

      def date_string(value)
        return nil if value.nil?

        value.to_date.iso8601
      end
  end
end
