module Forecast
  class DebtProjectionAdapter
    def initialize(family:, user:, periods:, money_converter:, recurring_items:, included_account_scope:, forecast_debt_events: [])
      @family = family
      @user = user
      @periods = periods
      @money_converter = money_converter
      @recurring_items = recurring_items
      @included_account_scope = included_account_scope
      @forecast_debt_events = forecast_debt_events
    end

    def call
      accounts.map { |account| rows_for(account) }.flatten
    end

    private
      attr_reader :family, :user, :periods, :money_converter, :recurring_items, :included_account_scope, :forecast_debt_events

      def accounts
        family.accounts.visible.liabilities
          .where(id: included_account_scope.ids)
          .includes(:debt_obligations, :debt_payment_allocations, debt_profile: :debt_rate_periods)
          .order(:accountable_type, :name, :id)
      end

      def rows_for(account)
        profile = account.debt_profile
        opening = money_converter.convert(amount: account.balance.to_d, currency: account.currency, source: "debt_account:#{account.id}:opening_balance")
        base_reasons = base_projection_reasons(account, profile)

        if base_reasons.any?
          terms = Debt::AccountTerms.new(account, as_of: readiness_date).resolve
          reasons = base_reasons + terms.missing_fields.map { |field| "missing_#{field}" }
          return account_balance_only_rows(account, profile, opening, reasons)
        end

        balance = opening.amount
        native_interest_bearing_balance = native_interest_bearing_opening_balance(profile)
        native_accrued_interest_balance = native_accrued_interest_opening_balance(profile)
        forecast_last_accrued_on = profile.last_accrued_on

        periods.map do |period|
          terms = Debt::AccountTerms.new(account, as_of: period.end_date).resolve
          unless terms.accrual_ready?
            reasons = terms.missing_fields.map { |field| "missing_#{field}" }
            row = account_balance_only_row(account, profile, opening, terms, period, balance, reasons)
            if native_interest_bearing_balance.present?
              native_balances = reduce_native_federal_balances(native_interest_bearing_balance, native_accrued_interest_balance, row.fetch(:projected_payment), opening)
              native_interest_bearing_balance = native_balances.fetch(:interest_bearing_principal)
              native_accrued_interest_balance = native_balances.fetch(:accrued_interest)
            end
            balance = row.fetch(:ending_balance)
            next row
          end

          payment = terms.monthly_payment.present? ? money_converter.convert(amount: terms.monthly_payment, currency: terms.currency, source: "debt_account:#{account.id}:monthly_payment:#{period.end_date}") : nil
          terms_valid_from = terms_valid_from_for(profile, period.end_date)
          scenario_effect = debt_scenario_effect_for(account, period)
          opening_balance = [ balance + scenario_effect.fetch(:drawdown), 0.to_d ].max
          projected_interest = projected_interest_for(
            account,
            profile,
            terms,
            period,
            opening_balance,
            opening,
            forecast_last_accrued_on: forecast_last_accrued_on,
            terms_valid_from: terms_valid_from,
            native_interest_bearing_balance: native_interest_bearing_balance,
            native_accrued_interest_balance: native_accrued_interest_balance
          )
          projected_interest_amount = projected_interest.fetch(:amount)
          forecast_last_accrued_on = projected_interest.fetch(:forecast_last_accrued_on) || forecast_last_accrued_on
          native_accrued_interest_balance += projected_native_amount(projected_interest_amount, opening)
          projected_interest_amount += scenario_effect.fetch(:interest)
          native_accrued_interest_balance += projected_native_amount(scenario_effect.fetch(:interest), opening)
          scenario_payment = [ scenario_effect.fetch(:payment), opening_balance + projected_interest_amount ].min
          required_payment = required_payment_for(account, period, payment, opening_balance, include_overdue: period == periods.first)
          required_payment_amount = [ required_payment.fetch(:amount), opening_balance + projected_interest_amount ].min
          actual_payment = actual_payment_for(account, period)
          recurring_payment = recurring_payment_for(account, period)
          actual_payment_credit = required_payment.fetch(:already_net_of_actuals) ? 0.to_d : actual_payment.fetch(:amount)
          fulfilled_payment = actual_payment_credit + recurring_payment + scenario_payment
          cash_payment_gap = [ required_payment_amount - fulfilled_payment, 0.to_d ].max
          projected_payment = [ scenario_payment + recurring_payment + cash_payment_gap, opening_balance + projected_interest_amount ].min
          ending_balance = [ opening_balance + projected_interest_amount - projected_payment, 0.to_d ].max
          if native_interest_bearing_balance.present?
            native_balances = reduce_native_federal_balances(native_interest_bearing_balance, native_accrued_interest_balance, projected_payment, opening)
            native_interest_bearing_balance = native_balances.fetch(:interest_bearing_principal)
            native_accrued_interest_balance = native_balances.fetch(:accrued_interest)
          end
          balance = ending_balance

          {
            projection_key: account.id,
            account_id: account.id,
            debt_profile_id: profile&.id,
            period_start_on: period.start_date,
            period_end_on: period.end_date,
            currency: money_converter.currency,
            opening_balance: opening_balance,
            projected_interest: projected_interest_amount,
            projected_payment: projected_payment,
            cash_payment_gap: cash_payment_gap,
            projected_drawdown: scenario_effect.fetch(:drawdown),
            ending_balance: ending_balance,
            source: "debt_profile_snapshot",
            risk_flags: opening.risk_flags + projected_interest.fetch(:risk_flags) + scenario_effect.fetch(:risk_flags) + Array(payment&.risk_flags) + required_payment.fetch(:risk_flags) + actual_payment.fetch(:risk_flags) + payment_missing_flags(account, terms),
            source_snapshot: source_snapshot_for(account, profile, opening, payment, terms).merge(
              "projected_interest" => projected_interest.fetch(:source_snapshot),
              "forecast_debt_events" => scenario_effect.fetch(:source_snapshot),
              "required_payment" => required_payment.fetch(:source_snapshot),
              "actual_payment_fulfilled" => actual_payment_credit.to_s,
              "actual_payment_already_reflected" => required_payment.fetch(:already_net_of_actuals) ? actual_payment.fetch(:amount).to_s : "0",
              "actual_payment_allocations" => actual_payment.fetch(:source_snapshot),
              "forecast_event_payment_fulfilled" => scenario_payment.to_s,
              "recurring_payment_fulfilled" => recurring_payment.to_s,
              "cash_payment_gap" => cash_payment_gap.to_s
            )
          }
        end
      end

      def base_projection_reasons(account, profile)
        reasons = []
        reasons << "missing_active_debt_profile" unless profile&.active?
        reasons << "unsupported_non_manual_debt_account" unless account.manual_debt_account?
        reasons << "auto_accrual_disabled" unless profile&.auto_accrual_enabled?
        reasons
      end

      def account_balance_only_rows(account, profile, opening, reasons)
        balance = opening.amount

        periods.map do |period|
          terms = Debt::AccountTerms.new(account, as_of: period.end_date).resolve
          row = account_balance_only_row(account, profile, opening, terms, period, balance, reasons)
          balance = row.fetch(:ending_balance)
          row
        end
      end

      def account_balance_only_row(account, profile, opening, terms, period, balance, reasons)
        payment = terms.monthly_payment.present? ? money_converter.convert(amount: terms.monthly_payment, currency: terms.currency, source: "debt_account:#{account.id}:monthly_payment:#{period.end_date}") : nil
        scenario_effect = debt_scenario_effect_for(account, period)
        opening_balance = [ balance + scenario_effect.fetch(:drawdown), 0.to_d ].max
        scenario_interest = scenario_effect.fetch(:interest)
        scenario_payment = [ scenario_effect.fetch(:payment), opening_balance + scenario_interest ].min
        required_payment = required_payment_for(account, period, payment, opening_balance, include_overdue: period == periods.first)
        required_payment_amount = [ required_payment.fetch(:amount), opening_balance + scenario_interest ].min
        actual_payment = actual_payment_for(account, period)
        recurring_payment = recurring_payment_for(account, period)
        actual_payment_credit = required_payment.fetch(:already_net_of_actuals) ? 0.to_d : actual_payment.fetch(:amount)
        fulfilled_payment = actual_payment_credit + recurring_payment + scenario_payment
        cash_payment_gap = [ required_payment_amount - fulfilled_payment, 0.to_d ].max
        projected_payment = [ scenario_payment + recurring_payment + cash_payment_gap, opening_balance + scenario_interest ].min
        ending_balance = [ opening_balance + scenario_interest - projected_payment, 0.to_d ].max

        {
          projection_key: account.id,
          account_id: account.id,
          debt_profile_id: profile&.id,
          period_start_on: period.start_date,
          period_end_on: period.end_date,
          currency: money_converter.currency,
          opening_balance: opening_balance,
          projected_interest: scenario_interest,
          projected_payment: projected_payment,
          cash_payment_gap: cash_payment_gap,
          projected_drawdown: scenario_effect.fetch(:drawdown),
          ending_balance: ending_balance,
          source: "account_balance_only",
          risk_flags: opening.risk_flags + Array(payment&.risk_flags) + scenario_effect.fetch(:risk_flags) + required_payment.fetch(:risk_flags) + actual_payment.fetch(:risk_flags) + reasons.map { |reason| { "type" => "debt_projection_incomplete", "account_id" => account.id, "reason" => reason } },
          source_snapshot: source_snapshot_for(account, profile, opening, payment, terms).merge(
            "incomplete_reasons" => reasons,
            "forecast_debt_events" => scenario_effect.fetch(:source_snapshot),
            "required_payment" => required_payment.fetch(:source_snapshot),
            "actual_payment_fulfilled" => actual_payment_credit.to_s,
            "actual_payment_already_reflected" => required_payment.fetch(:already_net_of_actuals) ? actual_payment.fetch(:amount).to_s : "0",
            "actual_payment_allocations" => actual_payment.fetch(:source_snapshot),
            "forecast_event_payment_fulfilled" => scenario_payment.to_s,
            "recurring_payment_fulfilled" => recurring_payment.to_s,
            "cash_payment_gap" => cash_payment_gap.to_s
          )
        }
      end

      def source_snapshot_for(account, profile, opening, payment, terms)
        {
          "account_id" => account.id,
          "account_name" => account.name,
          "account_currency" => account.currency,
          "debt_profile_id" => profile&.id,
          "debt_profile_status" => profile&.status,
          "last_accrued_on" => profile&.last_accrued_on&.iso8601,
          "annual_rate" => terms&.annual_rate&.to_s,
          "terms_source" => terms&.source,
          "missing_fields" => terms&.missing_fields || [],
          "monthly_payment_missing" => terms.present? && !required_payment_configured?(account, terms),
          "opening_balance" => money_converter.snapshot_for(opening),
          "monthly_payment" => payment ? money_converter.snapshot_for(payment) : {}
        }
      end

      def payment_missing_flags(account, terms)
        return [] if required_payment_configured?(account, terms)

        [
          {
            "type" => "debt_payment_schedule_incomplete",
            "account_id" => account.id,
            "reason" => "missing_monthly_payment"
          }
        ]
      end

      def required_payment_configured?(account, terms)
        profile = account.debt_profile
        terms.monthly_payment.present? || profile&.minimum_payment_percent.present?
      end

      def interest_projection_ready?(account, profile, terms)
        account.manual_debt_account? &&
          profile&.active? &&
          profile.auto_accrual_enabled? &&
          terms.accrual_ready?
      end

      def projected_interest_for(account, profile, terms, period, opening_balance, opening_conversion, forecast_last_accrued_on:, terms_valid_from: nil, native_interest_bearing_balance: nil, native_accrued_interest_balance: 0.to_d)
        unless terms.accrual_ready?
          return zero_projected_interest(
            "terms_not_accrual_ready",
            risk_flags: terms.missing_fields.map { |field| { "type" => "debt_projection_incomplete", "account_id" => account.id, "reason" => "missing_#{field}" } }
          )
        end

        window = forecast_accrual_window(profile, as_of: period.end_date, forecast_last_accrued_on: forecast_last_accrued_on)
        return zero_projected_interest("accrual_schedule_not_due") unless window.fetch(:due)

        period_end = [ period.end_date, window.fetch(:period_end_on) ].min
        start_date = [ Date.current, window.fetch(:period_start_on), terms_valid_from ].compact.max
        return zero_projected_interest("no_days_in_period") if start_date > period_end
        federal_handler = Debt::FederalStudentLoan::AccrualHandler.new(profile)
        unless federal_handler.accrues_interest?
          return zero_projected_interest(
            "non_accruing_federal_period",
            forecast_last_accrued_on: period_end,
            period_start_on: start_date,
            period_end_on: period_end
          )
        end

        terms = Debt::AccountTerms.new(account, as_of: period_end).resolve
        unless terms.accrual_ready?
          return zero_projected_interest(
            "terms_not_accrual_ready",
            risk_flags: terms.missing_fields.map { |field| { "type" => "debt_projection_incomplete", "account_id" => account.id, "reason" => "missing_#{field}" } }
          )
        end

        days = (period_end - start_date).to_i + 1
        denominator = federal_handler.day_count_denominator
        basis = projected_interest_basis(account, profile, federal_handler, terms, opening_balance, opening_conversion, period_end, native_interest_bearing_balance: native_interest_bearing_balance, native_accrued_interest_balance: native_accrued_interest_balance)
        projected_interest = (basis.fetch(:amount) * (terms.annual_rate.to_d / 100) * days / denominator).round(4)

        {
          amount: projected_interest,
          forecast_last_accrued_on: period_end,
          risk_flags: basis.fetch(:risk_flags),
          source_snapshot: basis.fetch(:source_snapshot).merge(
            "amount" => projected_interest.to_s,
            "currency" => money_converter.currency,
            "period_start_on" => start_date.iso8601,
            "period_end_on" => period_end.iso8601,
            "terms_valid_from" => terms_valid_from&.iso8601,
            "federal_policy_applied" => federal_handler.enabled?
          )
        }
      end

      def terms_valid_from_for(profile, as_of)
        rate_period = profile.debt_rate_periods.for_date(as_of).first

        [ profile.effective_start_on, rate_period&.starts_on ].compact.max
      end

      def projected_interest_basis(account, profile, federal_handler, terms, opening_balance, opening_conversion, period_end, native_interest_bearing_balance: nil, native_accrued_interest_balance: 0.to_d)
        native_opening_balance = projected_native_opening_balance(terms, opening_balance, opening_conversion)
        return non_federal_interest_basis(account, terms, opening_balance, native_opening_balance, period_end) unless federal_handler.enabled?

        native_policy_basis = native_federal_policy_basis(profile, federal_handler, native_opening_balance, native_interest_bearing_balance)
        converted_policy_basis = money_converter.convert(
          amount: native_policy_basis,
          currency: terms.currency,
          source: "debt_account:#{account.id}:federal_interest_basis:#{period_end}",
          as_of: money_converter.as_of
        )
        basis = [ converted_policy_basis.amount, opening_balance.to_d ].min

        {
          amount: basis,
          risk_flags: converted_policy_basis.risk_flags,
          source_snapshot: money_converter.snapshot_for(converted_policy_basis).merge(
            "basis" => basis.to_s,
            "basis_currency" => money_converter.currency,
            "carried_opening_balance" => opening_balance.to_s,
            "native_opening_balance" => native_opening_balance.to_s,
            "native_policy_basis" => native_policy_basis.to_s,
            "carried_native_interest_bearing_principal_balance" => native_interest_bearing_balance&.to_s,
            "carried_native_accrued_interest_balance" => native_accrued_interest_balance.to_s,
            "native_currency" => terms.currency,
            "basis_capped_to_carried_balance" => basis < converted_policy_basis.amount
          )
        }
      end

      def native_federal_policy_basis(profile, federal_handler, native_opening_balance, native_interest_bearing_balance)
        federal_profile = profile.federal_student_loan
        if federal_profile.subsidy_type == "mixed" &&
            Debt::FederalStudentLoan::InterestPolicy::NON_ACCRUING_SUBSIDIZED_STATUSES.include?(federal_profile.school_status)
          return [ native_interest_bearing_balance || federal_profile.interest_bearing_principal_balance, native_opening_balance ].min
        end

        federal_handler.interest_basis_amount(account_balance: native_opening_balance)
      end

      def projected_native_opening_balance(terms, opening_balance, opening_conversion)
        return opening_balance.to_d if terms.currency == money_converter.currency

        rate = opening_conversion.exchange_rate.to_d
        return terms.opening_balance.to_d if rate.zero?

        (opening_balance.to_d / rate).round(4)
      end

      def non_federal_interest_basis(account, terms, opening_balance, native_opening_balance, period_end)
        converted_basis = money_converter.convert(
          amount: native_opening_balance,
          currency: terms.currency,
          source: "debt_account:#{account.id}:interest_basis:#{period_end}",
          as_of: money_converter.as_of
        )

        {
          amount: opening_balance.to_d,
          risk_flags: converted_basis.risk_flags,
          source_snapshot: money_converter.snapshot_for(converted_basis).merge(
            "basis" => opening_balance.to_d.to_s,
            "basis_currency" => money_converter.currency,
            "carried_opening_balance" => opening_balance.to_d.to_s,
            "native_opening_balance" => native_opening_balance.to_s,
            "native_currency" => terms.currency
          )
        }
      end

      def zero_projected_interest(reason, forecast_last_accrued_on: nil, period_start_on: nil, period_end_on: nil, risk_flags: [])
        {
          amount: 0.to_d,
          forecast_last_accrued_on: forecast_last_accrued_on,
          risk_flags: risk_flags,
          source_snapshot: {
            "amount" => "0.0",
            "reason" => reason,
            "period_start_on" => period_start_on&.iso8601,
            "period_end_on" => period_end_on&.iso8601
          }.compact
        }
      end

      def forecast_accrual_window(profile, as_of:, forecast_last_accrued_on:)
        period_end = forecast_accrual_period_end(profile, as_of)
        period_start = [ forecast_last_accrued_on&.next_day, profile.effective_start_on ].compact.max || period_end
        due = (forecast_last_accrued_on.blank? || forecast_last_accrued_on < period_end) && period_start <= period_end

        { due: due, period_start_on: period_start, period_end_on: period_end }
      end

      def forecast_accrual_period_end(profile, as_of)
        return as_of unless profile.accrual_cadence == "monthly"

        anchor = monthly_anchor_for(profile, as_of)
        return anchor if anchor <= as_of

        monthly_anchor_for(profile, as_of.prev_month)
      end

      def monthly_anchor_for(profile, date)
        if profile.statement_closing_day.present?
          last_day = Date.new(date.year, date.month, -1).day
          Date.new(date.year, date.month, [ profile.statement_closing_day, last_day ].min)
        else
          Date.new(date.year, date.month, -1)
        end
      end

      def native_interest_bearing_opening_balance(profile)
        federal_profile = profile.federal_student_loan
        return nil unless federal_profile.enabled? && federal_profile.subsidy_type == "mixed"

        federal_profile.interest_bearing_principal_balance
      end

      def native_accrued_interest_opening_balance(profile)
        profile.federal_student_loan.accrued_interest_balance
      end

      def reduce_native_federal_balances(native_interest_bearing_balance, native_accrued_interest_balance, projected_payment, opening_conversion)
        native_payment = projected_native_amount(projected_payment, opening_conversion)
        interest_paid = [ native_payment, native_accrued_interest_balance ].min
        principal_payment = [ native_payment - interest_paid, 0.to_d ].max

        {
          accrued_interest: [ native_accrued_interest_balance - interest_paid, 0.to_d ].max,
          interest_bearing_principal: [ native_interest_bearing_balance.to_d - principal_payment, 0.to_d ].max
        }
      end

      def projected_native_amount(amount, opening_conversion)
        return amount.to_d if opening_conversion.native_currency == money_converter.currency

        rate = opening_conversion.exchange_rate.to_d
        return 0.to_d if rate.zero?

        (amount.to_d / rate).round(4)
      end

      def debt_scenario_effect_for(account, period)
        rows = forecast_debt_events.select do |row|
          debt_effect_account_id(row) == account.id &&
            period.start_date <= row.fetch(:date) && row.fetch(:date) <= period.end_date
        end

        {
          drawdown: rows.select { |row| row.fetch(:debt_delta, 0).to_d.positive? && row.fetch(:effect_type, nil) == "debt_drawdown" }.sum { |row| row.fetch(:debt_delta).to_d },
          payment: rows.select { |row| row.fetch(:debt_delta, 0).to_d.negative? && row.fetch(:transaction_kind, nil) == "loan_payment" }.sum { |row| -row.fetch(:debt_delta).to_d },
          interest: rows.select { |row| row.fetch(:debt_delta, 0).to_d.positive? && row.fetch(:transaction_kind, nil) == "debt_interest" }.sum { |row| row.fetch(:debt_delta).to_d },
          risk_flags: rows.flat_map { |row| row.fetch(:risk_flags, []) },
          source_snapshot: rows.map { |row| row.fetch(:source_snapshot, {}) }
        }
      end

      def debt_effect_account_id(row)
        row.fetch(:destination_account_id, nil) || row.fetch(:account_id, nil)
      end

      def required_payment_for(account, period, payment, opening_balance, include_overdue: false)
        obligations = account.debt_obligations
          .where(status: %w[open partially_paid overdue paid])
        obligations = if include_overdue
          obligations.where("due_on <= ?", period.end_date)
        else
          obligations.where(due_on: period.start_date..period.end_date)
        end
        obligations = obligations.order(:due_on, :id).to_a

        if obligations.any?
          converted = obligations.filter_map do |obligation|
            gross_amount = (obligation.minimum_payment_amount || obligation.statement_balance_amount || 0).to_d
            paid = eligible_paid_amount(obligation, target_currency: obligation.currency, as_of: period.end_date)
            paid_amount = paid.fetch(:amount)
            remaining_amount = [ gross_amount - paid_amount, 0.to_d ].max
            next if remaining_amount.zero?

            {
              obligation: obligation,
              gross_amount: gross_amount,
              paid_amount: paid_amount,
              paid_snapshot: paid.fetch(:source_snapshot),
              paid_risk_flags: paid.fetch(:risk_flags),
              remaining_amount: remaining_amount,
              converted: money_converter.convert(amount: remaining_amount, currency: obligation.currency, source: "debt_obligation:#{obligation.id}:remaining_payment", as_of: obligation.due_on)
            }
          end

          return {
            amount: converted.sum { |row| row.fetch(:converted).amount },
            already_net_of_actuals: true,
            risk_flags: converted.flat_map { |row| row.fetch(:converted).risk_flags + row.fetch(:paid_risk_flags) },
            source_snapshot: converted.map do |row|
              obligation = row.fetch(:obligation)
              {
                "debt_obligation_id" => obligation.id,
                "status" => obligation.status,
                "gross_amount" => row.fetch(:gross_amount).to_s,
                "paid_amount" => row.fetch(:paid_amount).to_s,
                "paid_amount_currency" => obligation.currency,
                "paid_allocations" => row.fetch(:paid_snapshot),
                "remaining_amount" => row.fetch(:remaining_amount).to_s,
                "money" => money_converter.snapshot_for(row.fetch(:converted))
              }
            end
          }
        end

        fallback = fallback_required_payment_for(account, payment, opening_balance)
        {
          amount: fallback.fetch(:amount),
          already_net_of_actuals: false,
          risk_flags: fallback.fetch(:risk_flags),
          source_snapshot: fallback.fetch(:source_snapshot)
        }
      end

      def fallback_required_payment_for(account, payment, opening_balance)
        percent_amount = percent_minimum_payment_for(account, opening_balance)
        fixed_amount = payment&.amount
        selected_amount = [ fixed_amount, percent_amount ].compact.max || 0.to_d
        selected_source = if percent_amount.present? && selected_amount == percent_amount
          "minimum_payment_percent"
        elsif fixed_amount.present?
          "fixed_minimum_payment"
        else
          "none"
        end

        {
          amount: selected_amount,
          risk_flags: Array(payment&.risk_flags),
          source_snapshot: {
            "selected_source" => selected_source,
            "fixed_minimum_payment" => payment ? money_converter.snapshot_for(payment) : {},
            "minimum_payment_percent" => account.debt_profile&.minimum_payment_percent&.to_s,
            "percent_minimum_payment_amount" => percent_amount&.to_s
          }
        }
      end

      def percent_minimum_payment_for(account, opening_balance)
        percent = account.debt_profile&.minimum_payment_percent
        return nil if percent.blank?

        (opening_balance.to_d * percent.to_d / 100).round(4)
      end

      def eligible_paid_amount(obligation, target_currency:, as_of:)
        allocations = obligation.debt_payment_allocations.to_a
        if allocations.empty?
          return { amount: obligation.paid_amount.to_d, risk_flags: [], source_snapshot: [] }
        end

        converted = allocations.select { |allocation| eligible_paid_allocation?(allocation, as_of) }.map do |allocation|
          native_amount = allocation.component_total - allocation.unapplied_amount
          converted_amount = convert_native_currency_amount(
            amount: native_amount,
            from_currency: allocation.currency,
            to_currency: target_currency,
            as_of: allocation.entry.date,
            source: "debt_payment_allocation:#{allocation.id}:paid_amount"
          )

          {
            allocation: allocation,
            native_amount: native_amount,
            converted_amount: converted_amount
          }
        end

        {
          amount: converted.sum { |row| row.fetch(:converted_amount).fetch(:amount) },
          risk_flags: converted.flat_map { |row| row.fetch(:converted_amount).fetch(:risk_flags) },
          source_snapshot: converted.map do |row|
            allocation = row.fetch(:allocation)
            {
              "debt_payment_allocation_id" => allocation.id,
              "native_amount" => row.fetch(:native_amount).to_s,
              "native_currency" => allocation.currency,
              "converted_amount" => row.fetch(:converted_amount).fetch(:amount).to_s,
              "converted_currency" => target_currency,
              "exchange_rate" => row.fetch(:converted_amount).fetch(:exchange_rate)&.to_s,
              "exchange_rate_date" => row.fetch(:converted_amount).fetch(:exchange_rate_date)&.iso8601
            }
          end
        }
      end

      def eligible_paid_allocation?(allocation, as_of)
        cutoff_date = [ as_of, Date.current ].min
        return false unless allocation.status.in?(%w[allocated estimated])
        return false if allocation.entry.blank?
        return false if allocation.entry.date.blank? || allocation.entry.date > cutoff_date
        return false if allocation.entry.excluded?
        return false if allocation.entry.transaction? && allocation.entry.transaction.pending?

        true
      end

      def convert_native_currency_amount(amount:, from_currency:, to_currency:, as_of:, source:)
        return { amount: 0.to_d, exchange_rate: nil, exchange_rate_date: nil, risk_flags: [] } if amount.to_d.zero?
        return { amount: amount.to_d, exchange_rate: 1.to_d, exchange_rate_date: as_of, risk_flags: [] } if from_currency == to_currency

        rate = ExchangeRate.find_or_fetch_rate(from: from_currency, to: to_currency, date: as_of, cache: false)
        raise Forecast::MoneyConverter::MissingRate, "Missing FX rate #{from_currency}->#{to_currency} for #{as_of} while converting #{source}" if rate.blank?

        {
          amount: amount.to_d * rate.rate.to_d,
          exchange_rate: rate.rate.to_d,
          exchange_rate_date: rate.date,
          risk_flags: rate.date == as_of ? [] : [ { "type" => "stale_fx_rate", "source" => source, "from_currency" => from_currency, "to_currency" => to_currency, "requested_date" => as_of.iso8601, "rate_date" => rate.date.iso8601 } ]
        }
      end

      def readiness_date
        [ periods.first.start_date, Date.current ].max
      end

      def actual_payment_for(account, period)
        allocations = account.debt_payment_allocations
          .joins(:entry)
          .includes(:entry)
          .where(status: %w[allocated estimated])
          .where(entries: { date: period.start_date..[ period.end_date, Date.current ].min })
          .order("entries.date ASC", "debt_payment_allocations.id ASC")
          .to_a
          .reject { |allocation| allocation.entry.excluded? || (allocation.entry.transaction? && allocation.entry.transaction.pending?) }

        converted = allocations.map do |allocation|
          money_converter.convert(
            amount: allocation.component_total,
            currency: allocation.currency,
            source: "debt_payment_allocation:#{allocation.id}:component_total",
            as_of: allocation.entry.date
          )
        end

        {
          amount: converted.sum(&:amount),
          risk_flags: converted.flat_map(&:risk_flags),
          source_snapshot: allocations.zip(converted).map do |allocation, row|
            {
              "debt_payment_allocation_id" => allocation.id,
              "status" => allocation.status,
              "entry_id" => allocation.entry_id,
              "entry_date" => allocation.entry.date&.iso8601,
              "entry_name" => allocation.entry.name,
              "signed_entry_amount" => allocation.entry.amount.to_s,
              "principal_amount" => allocation.principal_amount.to_s,
              "interest_amount" => allocation.interest_amount.to_s,
              "fee_amount" => allocation.fee_amount.to_s,
              "unapplied_amount" => allocation.unapplied_amount.to_s,
              "component_total" => allocation.component_total.to_s,
              "money" => money_converter.snapshot_for(row)
            }
          end
        }
      end

      def recurring_payment_for(account, period)
        recurring_items
          .select { |row| row.fetch(:destination_account_id) == account.id }
          .select { |row| row.fetch(:transaction_kind).in?(%w[cc_payment loan_payment]) }
          .select { |row| row.fetch(:recurring_payment_modeled, true) }
          .select { |row| period.start_date <= row.fetch(:date) && row.fetch(:date) <= period.end_date }
          .sum(0.to_d) { |row| row.fetch(:amount).to_d }
      end
  end
end
