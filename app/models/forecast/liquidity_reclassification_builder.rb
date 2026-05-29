module Forecast
  # Emits deterministic dated reclassification effects that move an account's
  # EXISTING opening balance between liquidity buckets (cash/liquid/restricted/
  # illiquid/debt) as forecast liquidity setting windows open and close over the
  # horizon.
  #
  # Reclassification is balance-neutral: it only re-buckets the SAME money, so it
  # never creates phantom income or spending. Each emitted row carries cash_delta
  # and liquid_delta shaped like the engine's other effect rows (the engine tracks
  # the cash bucket and the liquid bucket, where the liquid bucket INCLUDES cash),
  # plus source metadata describing the move.
  #
  # The builder is pure: the run date is threaded in explicitly and no wall-clock
  # read or RNG is used. Settings are resolved through Forecast::LiquidityClassifier
  # so overlapping baseline + scenario windows collapse to the same highest-priority
  # class the rest of the engine sees, and rows are materialized in a stable order
  # (account_id, effective_on, then setting-driven boundaries) before being returned.
  class LiquidityReclassificationBuilder
    # Buckets that participate in the cash running balance and the liquid running
    # balance (the liquid bucket is a superset of cash, matching Engine#opening_liquid).
    CASH_CLASSES = %w[cash].freeze
    LIQUID_CLASSES = %w[cash liquid].freeze

    def initialize(family:, scenario_ids:, accounts:, periods:, run_date:)
      @family = family
      @scenario_ids = Array(scenario_ids).compact_blank
      @accounts = accounts
      @periods = periods
      @run_date = run_date
    end

    def call
      return [] if horizon_start.blank? || horizon_end.blank?

      rows = ordered_account_rows.flat_map { |account_row| effects_for(account_row) }
      rows.sort_by do |row|
        meta = row.fetch(:source_snapshot)
        [ meta.fetch("account_id").to_s, row.fetch(:date), meta.fetch("to_class") ]
      end
    end

    private
      attr_reader :family, :scenario_ids, :accounts, :periods, :run_date

      # Stable iteration order independent of DB row order: account input rows sorted
      # by their id before any effects are produced.
      def ordered_account_rows
        accounts.sort_by { |row| row.fetch(:id).to_s }
      end

      def effects_for(account_row)
        account = account_records.fetch(account_row.fetch(:id), nil)
        return [] if account.blank?

        balance = account_row.fetch(:balance).to_d
        return [] if balance.zero?

        transitions(account).filter_map do |on, to_class, from_class|
          next if from_class == to_class

          effect_row(
            account_row: account_row,
            account: account,
            balance: balance,
            on: on,
            from_class: from_class,
            to_class: to_class
          )
        end
      end

      # Walks the candidate boundary dates within the horizon and reads the effective
      # liquidity class on each side, emitting a transition whenever the class changes.
      # Driving this purely off the classifier's resolution means overlapping baseline
      # and scenario settings collapse to the same highest-priority class the engine
      # uses elsewhere, and a window that ends reverts on E.next_day.
      def transitions(account)
        boundaries = boundary_dates(account)
        previous_class = effective_class(account, run_date)
        result = []

        boundaries.each do |date|
          current_class = effective_class(account, date)
          result << [ date, current_class, previous_class ]
          previous_class = current_class
        end

        result
      end

      # Candidate dates where an account's effective class can change: each relevant
      # setting's effective start, and the day after each relevant setting's effective
      # end (boundary precision so the revert lands on E.next_day). Clamped to the
      # horizon and de-duplicated; the run date itself is never a boundary because the
      # opening balance is already bucketed there.
      def boundary_dates(account)
        dates = settings_for(account.id).flat_map do |setting|
          starts_on, ends_on = effective_window(setting)
          [ starts_on, ends_on&.next_day ].compact
        end

        dates
          .select { |date| date > run_date && date >= horizon_start && date <= horizon_end }
          .uniq
          .sort
      end

      def effective_window(setting)
        starts_on = [ setting.starts_on, setting.forecast_scenario&.starts_on ].compact.max
        ends_on = [ setting.ends_on, setting.forecast_scenario&.ends_on ].compact.min
        [ starts_on, ends_on ]
      end

      def effective_class(account, on)
        classifier.call(account, on: on)
      end

      def effect_row(account_row:, account:, balance:, on:, from_class:, to_class:)
        cash_delta = bucket_delta(balance, from_class, to_class, CASH_CLASSES)
        liquid_delta = bucket_delta(balance, from_class, to_class, LIQUID_CLASSES)

        {
          date: on,
          name: "Liquidity reclassification",
          effect_type: "liquidity_reclassification",
          account_id: account.id,
          expected_income: 0.to_d,
          expected_spending: 0.to_d,
          cash_delta: cash_delta,
          liquid_delta: liquid_delta,
          debt_delta: 0.to_d,
          portfolio_delta: 0.to_d,
          net_worth_delta: 0.to_d,
          budget_flow_type: "none",
          transaction_kind: "liquidity_reclassification",
          source_snapshot: {
            "type" => "liquidity_reclassification",
            "account_id" => account.id,
            "from_class" => from_class,
            "to_class" => to_class,
            "effective_on" => on.iso8601,
            "balance" => balance.to_s,
            "cash_delta" => cash_delta.to_s,
            "liquid_delta" => liquid_delta.to_s
          },
          risk_flags: []
        }
      end

      # +balance entering the bucket, -balance leaving it, 0 if membership is unchanged.
      def bucket_delta(balance, from_class, to_class, member_classes)
        entering = member_classes.include?(to_class)
        leaving = member_classes.include?(from_class)
        return 0.to_d if entering == leaving

        entering ? balance : -balance
      end

      def settings_for(account_id)
        settings_by_account.fetch(account_id, [])
      end

      # All baseline + in-stack scenario settings for the included accounts, sorted with
      # the SAME priority ordering Forecast::LiquidityClassifier uses, then grouped by
      # account. Ordering is fully deterministic and independent of DB row order.
      def settings_by_account
        @settings_by_account ||= begin
          scenario_order = scenario_ids.each_with_index.to_h
          family.forecast_account_liquidity_settings
            .where(forecast_scenario_id: [ nil, *scenario_ids ])
            .where(account_id: account_records.keys)
            .includes(:forecast_scenario)
            .to_a
            .sort_by { |setting| [ setting.forecast_scenario_id ? scenario_order.fetch(setting.forecast_scenario_id, 0) + 1 : 0, setting.updated_at || Time.at(0), setting.account_id.to_s, setting.id ] }
            .group_by(&:account_id)
        end
      end

      def account_records
        @account_records ||= family.accounts
          .where(id: accounts.map { |row| row.fetch(:id) })
          .index_by(&:id)
      end

      def classifier
        @classifier ||= Forecast::LiquidityClassifier.new(family: family, scenario_ids: scenario_ids)
      end

      def horizon_start
        @horizon_start ||= periods.days.first || periods.months.first&.start_date
      end

      def horizon_end
        @horizon_end ||= periods.months.last&.end_date || periods.days.last
      end
  end
end
