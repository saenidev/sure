module Forecast
  class DebtProjectionAdapter
    # Sources that mark a locally-derived (Sure-generated or manual) obligation.
    # Anything else with an external_id is treated as provider-supplied and wins
    # the due amount within its due window. "" is included so a blank-string
    # source behaves like nil.
    LOCAL_OBLIGATION_SOURCES = [ "", "manual", "sure", "local" ].freeze

    def initialize(family:, user:, periods:, money_converter:, recurring_items:, included_account_scope:, forecast_debt_events: [], run_date: nil)
      @family = family
      @user = user
      @periods = periods
      @money_converter = money_converter
      @recurring_items = recurring_items
      @included_account_scope = included_account_scope
      @forecast_debt_events = forecast_debt_events
      @run_date = run_date || money_converter.as_of
    end

    def call
      accounts.map { |account| rows_for(account) }.flatten
    end

    private
      attr_reader :family, :user, :periods, :money_converter, :recurring_items, :included_account_scope, :forecast_debt_events, :run_date

      # Resolve debt terms for an account at a date WITHOUT re-querying rate periods
      # per call. We materialize the account's freshly eager-loaded debt_rate_periods
      # into a stable, frozen array ONCE per account (ordered by starts_on, priority,
      # id for deterministic, DB-order-independent resolution) and inject it into
      # AccountTerms. Because the adapter eager-loads fresh and never mutates rate
      # periods during `call`, the snapshot is authoritative and the per-period
      # AccountTerms resolution issues zero additional DB queries.
      def resolve_terms(account, as_of)
        Debt::AccountTerms.new(account, as_of: as_of, rate_periods: rate_periods_snapshot(account)).resolve
      end

      def rate_periods_snapshot(account)
        @rate_periods_snapshots ||= {}
        @rate_periods_snapshots[account.id] ||= begin
          profile = account.debt_profile
          (profile&.debt_rate_periods || [])
            .sort_by { |rate_period| [ rate_period.starts_on, rate_period.priority, rate_period.id ] }
            .freeze
        end
      end

      def accounts
        family.accounts.visible.liabilities
          .where(id: included_account_scope.ids)
          .includes(
            { debt_obligations: { debt_payment_allocations: :entry } },
            { debt_payment_allocations: :entry },
            debt_profile: :debt_rate_periods
          )
          .order(:accountable_type, :name, :id)
      end

      def rows_for(account)
        profile = account.debt_profile
        opening = money_converter.convert(amount: account.balance.to_d, currency: account.currency, source: "debt_account:#{account.id}:opening_balance")
        base_reasons = base_projection_reasons(account, profile)

        if base_reasons.any?
          terms = resolve_terms(account, readiness_date)
          reasons = base_reasons + terms.missing_fields.map { |field| "missing_#{field}" }
          return account_balance_only_rows(account, profile, opening, reasons)
        end

        balance = opening.amount
        native_interest_bearing_balance = native_interest_bearing_opening_balance(profile)
        native_accrued_interest_balance = native_accrued_interest_opening_balance(profile)
        forecast_last_accrued_on = profile.last_accrued_on

        rows = periods.map do |period|
          terms = resolve_terms(account, period.end_date)
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

          refinance = refinance_override_for(account, period)
          effective_terms = refinance.fetch(:active) ? refinance.fetch(:terms) : terms
          payment = effective_terms.monthly_payment.present? ? money_converter.convert(amount: effective_terms.monthly_payment, currency: effective_terms.currency, source: "debt_account:#{account.id}:monthly_payment:#{period.end_date}") : nil
          scenario_effect = debt_scenario_effect_for(account, period)
          opening_balance = [ balance + scenario_effect.fetch(:drawdown) + refinance.fetch(:drawdown), 0.to_d ].max
          projected_interest = if refinance.fetch(:active)
            refinanced_projected_interest(account, profile, effective_terms, period, opening_balance, opening, forecast_last_accrued_on: forecast_last_accrued_on, refinance: refinance)
          else
            projected_interest_for(
              account,
              profile,
              terms,
              period,
              opening_balance,
              opening,
              forecast_last_accrued_on: forecast_last_accrued_on,
              native_interest_bearing_balance: native_interest_bearing_balance,
              native_accrued_interest_balance: native_accrued_interest_balance
            )
          end
          projected_interest_amount = projected_interest.fetch(:amount)
          forecast_last_accrued_on = projected_interest.fetch(:forecast_last_accrued_on) || forecast_last_accrued_on
          native_accrued_interest_balance += projected_native_amount(projected_interest_amount, opening)
          projected_interest_amount += scenario_effect.fetch(:interest)
          native_accrued_interest_balance += projected_native_amount(scenario_effect.fetch(:interest), opening)
          balance_with_interest = opening_balance + projected_interest_amount
          scenario_payment = [ scenario_effect.fetch(:payment), balance_with_interest ].min
          balloon = balloon_payment_for(account, profile, opening, period, balance_with_interest)
          balloon_amount = balloon.fetch(:amount)
          required_payment = required_payment_for(account, period, payment, opening_balance, include_overdue: period == periods.first)
          required_payment_amount = [ required_payment.fetch(:amount) + balloon_amount, balance_with_interest ].min
          actual_payment = actual_payment_for(account, period)
          recurring_payment = recurring_payment_for(account, period)
          actual_payment_credit = required_payment.fetch(:already_net_of_actuals) ? 0.to_d : actual_payment.fetch(:amount)
          fulfilled_payment = actual_payment_credit + recurring_payment + scenario_payment
          cash_payment_gap = [ required_payment_amount - fulfilled_payment, 0.to_d ].max
          # The balloon is a contractually scheduled lump sum that already flows into
          # required_payment_amount (line above) and therefore into cash_payment_gap
          # when unfunded; it reduces the balance in its due period regardless of
          # whether cash covers it (the shortfall is surfaced separately via
          # cash_payment_gap). Do NOT re-add balloon_amount here or it is counted
          # twice, overpaying the loan and corrupting the ending balance / net worth.
          baseline_projected_payment = [ scenario_payment + recurring_payment + cash_payment_gap, balance_with_interest ].min
          amortization = amortization_extra_payment_for(
            account,
            profile,
            effective_terms,
            period,
            opening_balance,
            projected_interest_amount,
            baseline_projected_payment
          )
          applied_extra_payment = amortization.fetch(:applied_extra_payment)
          projected_payment = [ baseline_projected_payment + applied_extra_payment, balance_with_interest ].min
          ending_balance = [ balance_with_interest - projected_payment, 0.to_d ].max
          if native_interest_bearing_balance.present?
            native_balances = reduce_native_federal_balances(native_interest_bearing_balance, native_accrued_interest_balance, projected_payment, opening)
            native_interest_bearing_balance = native_balances.fetch(:interest_bearing_principal)
            native_accrued_interest_balance = native_balances.fetch(:accrued_interest)
          end
          balance = ending_balance

          balance_trend = balance_trend_for(opening_balance, ending_balance)

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
            projected_drawdown: scenario_effect.fetch(:drawdown) + refinance.fetch(:drawdown),
            ending_balance: ending_balance,
            balance_trend: balance_trend,
            source: "debt_profile_snapshot",
            risk_flags: opening.risk_flags + projected_interest.fetch(:risk_flags) + scenario_effect.fetch(:risk_flags) + Array(payment&.risk_flags) + required_payment.fetch(:risk_flags) + actual_payment.fetch(:risk_flags) + payment_missing_flags(account, effective_terms) + balance_growing_flags(account, balance_trend, projected_payment, projected_interest_amount) + amortization.fetch(:risk_flags) + balloon.fetch(:risk_flags) + refinance.fetch(:risk_flags),
            source_snapshot: source_snapshot_for(account, profile, opening, payment, effective_terms).merge(
              "projected_interest" => projected_interest.fetch(:source_snapshot),
              "forecast_debt_events" => scenario_effect.fetch(:source_snapshot),
              "required_payment" => required_payment.fetch(:source_snapshot),
              "actual_payment_fulfilled" => actual_payment_credit.to_s,
              "actual_payment_already_reflected" => required_payment.fetch(:already_net_of_actuals) ? actual_payment.fetch(:amount).to_s : "0",
              "actual_payment_allocations" => actual_payment.fetch(:source_snapshot),
              "forecast_event_payment_fulfilled" => scenario_payment.to_s,
              "recurring_payment_fulfilled" => recurring_payment.to_s,
              "cash_payment_gap" => cash_payment_gap.to_s,
              "baseline_projected_payment" => baseline_projected_payment.to_s,
              "amortization" => amortization.fetch(:source_snapshot),
              "balance_trend" => balance_trend,
              "debt_balloon_due" => balloon.fetch(:source_snapshot),
              "refinance" => refinance.fetch(:source_snapshot)
            )
          }
        end

        stamp_payoff_metadata(rows)
      end

      def base_projection_reasons(account, profile)
        reasons = []
        reasons << "missing_active_debt_profile" unless profile&.active?
        reasons << "unsupported_non_manual_debt_account" unless account.manual_debt_account?
        reasons << "auto_accrual_disabled" unless profile&.auto_accrual_enabled?
        reasons
      end

      # Classify a profile-backed row by how its balance moved across the period.
      # Reads only already-computed opening/ending balances so the result is
      # deterministic and never re-derives interest or payments.
      def balance_trend_for(opening_balance, ending_balance)
        if ending_balance > opening_balance
          "growing"
        elsif ending_balance < opening_balance
          "amortizing"
        else
          "flat"
        end
      end

      def balance_growing_flags(account, balance_trend, projected_payment, projected_interest)
        return [] unless balance_trend == "growing"
        return [] unless projected_payment < projected_interest

        [
          {
            "type" => "debt_balance_growing",
            "account_id" => account.id,
            "reason" => "interest_exceeds_payment"
          }
        ]
      end

      # Detect the first period whose ending balance reaches zero for a
      # profile-backed account and stamp payoff metadata on every row. Reads only
      # the already-computed ending balances; introduces no clock or RNG.
      def stamp_payoff_metadata(rows)
        # The payoff is the first period that reaches zero AND stays zero for the
        # rest of the horizon. A later drawdown/refinance that re-grows the balance
        # means the debt was not actually paid off, so do not stamp a payoff that
        # never sticks.
        payoff_row = rows.each_with_index.find { |row, i|
          row.fetch(:ending_balance).to_d.zero? &&
            rows[(i + 1)..].all? { |later| later.fetch(:ending_balance).to_d.zero? }
        }&.first
        payoff_projected_on = payoff_row&.fetch(:period_end_on)

        rows.map do |row|
          is_payoff_period = payoff_row.present? && row.equal?(payoff_row)
          source_snapshot = row.fetch(:source_snapshot).merge(
            "payoff_projected_on" => payoff_projected_on&.iso8601,
            "is_payoff_period" => is_payoff_period
          )
          row.merge(
            payoff_projected_on: payoff_projected_on,
            is_payoff_period: is_payoff_period,
            source_snapshot: source_snapshot
          )
        end
      end

      def account_balance_only_rows(account, profile, opening, reasons)
        balance = opening.amount

        periods.map do |period|
          terms = resolve_terms(account, period.end_date)
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

      def projected_interest_for(account, profile, terms, period, opening_balance, opening_conversion, forecast_last_accrued_on:, native_interest_bearing_balance: nil, native_accrued_interest_balance: 0.to_d)
        unless terms.accrual_ready?
          return zero_projected_interest(
            "terms_not_accrual_ready",
            risk_flags: terms.missing_fields.map { |field| { "type" => "debt_projection_incomplete", "account_id" => account.id, "reason" => "missing_#{field}" } }
          )
        end

        window = forecast_accrual_window(profile, as_of: period.end_date, forecast_last_accrued_on: forecast_last_accrued_on)
        return zero_projected_interest("accrual_schedule_not_due") unless window.fetch(:due)

        period_end = [ period.end_date, window.fetch(:period_end_on) ].min
        natural_start = [ run_date, window.fetch(:period_start_on), profile.effective_start_on ].compact.max
        # Clamp only the LEADING no-rate gap forward: if no rate period covers the
        # natural start, accrual begins at the first rate period that opens on or
        # before period_end. Intra-window rate transitions are handled by splitting
        # into sub-spans below rather than by clamping the whole period forward.
        leading_clamp = leading_rate_clamp_for(profile, natural_start, period_end)
        start_date = [ natural_start, leading_clamp ].compact.max
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

        # Resolve every rate-period boundary that falls strictly inside the
        # accrual window. Accruing the whole span at the end-of-span rate would
        # apply a rate to days before its starts_on; instead we split the span at
        # each boundary and accrue each sub-span at its own resolved rate, summing
        # the interest. Boundaries are collected with a stable, DB-order-independent
        # ordering (starts_on, priority, id) so overlapping/variable periods resolve
        # identically regardless of insertion order.
        spans = rate_spans_for(profile, start_date, period_end)
        denominator = federal_handler.day_count_denominator

        span_results = spans.map do |span|
          span_start = span.fetch(:start_on)
          span_end = span.fetch(:end_on)
          span_terms = resolve_terms(account, span_end)
          next { not_ready: span_terms } unless span_terms.accrual_ready?

          span_days = (span_end - span_start).to_i + 1
          span_basis = projected_interest_basis(account, profile, federal_handler, span_terms, opening_balance, opening_conversion, span_end, native_interest_bearing_balance: native_interest_bearing_balance, native_accrued_interest_balance: native_accrued_interest_balance)
          span_interest = (span_basis.fetch(:amount) * (span_terms.annual_rate.to_d / 100) * span_days / denominator).round(4)

          {
            terms: span_terms,
            basis: span_basis,
            days: span_days,
            interest: span_interest,
            start_on: span_start,
            end_on: span_end
          }
        end

        not_ready = span_results.find { |result| result.key?(:not_ready) }
        if not_ready
          span_terms = not_ready.fetch(:not_ready)
          return zero_projected_interest(
            "terms_not_accrual_ready",
            risk_flags: span_terms.missing_fields.map { |field| { "type" => "debt_projection_incomplete", "account_id" => account.id, "reason" => "missing_#{field}" } }
          )
        end

        projected_interest = span_results.sum(0.to_d) { |result| result.fetch(:interest) }
        # The basis snapshot is identical across sub-spans (same opening balance and
        # FX) so the final span's snapshot represents the period; per-span rate and
        # day-count detail lives under "rate_spans".
        final_basis = span_results.last.fetch(:basis)

        {
          amount: projected_interest,
          forecast_last_accrued_on: period_end,
          risk_flags: span_results.flat_map { |result| result.fetch(:basis).fetch(:risk_flags) },
          source_snapshot: final_basis.fetch(:source_snapshot).merge(
            "amount" => projected_interest.to_s,
            "currency" => money_converter.currency,
            "period_start_on" => start_date.iso8601,
            "period_end_on" => period_end.iso8601,
            "terms_valid_from" => start_date.iso8601,
            "federal_policy_applied" => federal_handler.enabled?,
            "rate_spans" => span_results.map do |result|
              {
                "start_on" => result.fetch(:start_on).iso8601,
                "end_on" => result.fetch(:end_on).iso8601,
                "days" => result.fetch(:days),
                "annual_rate" => result.fetch(:terms).annual_rate.to_s,
                "terms_source" => result.fetch(:terms).source,
                "interest" => result.fetch(:interest).to_s
              }
            end
          )
        }
      end

      # Split [start_date, period_end] at each DebtRatePeriod boundary that falls
      # strictly inside the window, so each sub-span accrues at its own resolved
      # rate. Boundaries come from rate periods whose starts_on lies in
      # (start_date, period_end]; iteration uses a stable (starts_on, priority, id)
      # ordering in Ruby so the result never depends on DB row order. Returns an
      # ordered, contiguous, gap-free list of { start_on:, end_on: } sub-spans.
      def rate_spans_for(profile, start_date, period_end)
        boundaries = profile.debt_rate_periods
          .sort_by { |rate_period| [ rate_period.starts_on, rate_period.priority, rate_period.id ] }
          .map(&:starts_on)
          .select { |starts_on| starts_on > start_date && starts_on <= period_end }
          .uniq

        cut_points = ([ start_date ] + boundaries).uniq
        cut_points.each_with_index.map do |span_start, index|
          next_boundary = cut_points[index + 1]
          span_end = next_boundary ? next_boundary.prev_day : period_end
          { start_on: span_start, end_on: span_end }
        end
      end

      # Forward-clamp the accrual start past a leading no-rate gap. If a rate
      # period already covers the natural start there is nothing to skip (returns
      # nil). Otherwise accrual cannot begin until the first rate period opens, so
      # we return the earliest rate-period start that lands inside the window.
      # Iterates with a stable (starts_on, priority, id) ordering so the clamp is
      # independent of DB row order.
      def leading_rate_clamp_for(profile, natural_start, period_end)
        ordered = profile.debt_rate_periods
          .sort_by { |rate_period| [ rate_period.starts_on, rate_period.priority, rate_period.id ] }
        return nil if ordered.any? { |rate_period| rate_period_covers?(rate_period, natural_start) }

        ordered
          .map(&:starts_on)
          .select { |starts_on| starts_on > natural_start && starts_on <= period_end }
          .min
      end

      def rate_period_covers?(rate_period, date)
        rate_period.starts_on <= date && (rate_period.ends_on.nil? || rate_period.ends_on >= date)
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

      # Read an optional one-time balloon payment from the profile's
      # extra["balloon"] = { "due_on", "amount", "currency" }. On the forecast
      # period whose window contains due_on, the FX-converted balloon is scheduled
      # as a lump-sum payment capped at the balance owed; outside the horizon it is
      # ignored. Foreign-currency balloons fail loud via MissingRate (the converter
      # raises) so a balloon is never silently assumed 1:1. Deterministic: due_on
      # is a fixed date and the amount is converted at the run-date as_of.
      def balloon_payment_for(account, profile, opening, period, balance_with_interest)
        config = balloon_config_for(profile)
        return no_balloon unless config

        due_on = parse_date(config["due_on"])
        return no_balloon if due_on.blank?
        return no_balloon unless period.start_date <= due_on && due_on <= period.end_date

        currency = config["currency"].presence || money_converter.currency
        converted = money_converter.convert(
          amount: config["amount"].to_d,
          currency: currency,
          source: "debt_account:#{account.id}:balloon_payment:#{due_on}"
        )
        capped = [ converted.amount, balance_with_interest ].min

        {
          amount: capped,
          risk_flags: converted.risk_flags + [
            {
              "type" => "debt_balloon_due",
              "account_id" => account.id,
              "due_on" => due_on.iso8601,
              "balloon_amount" => capped.to_s
            }
          ],
          source_snapshot: {
            "due_on" => due_on.iso8601,
            "configured_balloon" => money_converter.snapshot_for(converted),
            "scheduled_balloon_payment" => capped.to_s,
            "balloon_capped_to_balance" => capped < converted.amount
          }
        }
      end

      def balloon_config_for(profile)
        return nil if profile.blank?

        config = profile.extra.is_a?(Hash) ? profile.extra["balloon"] : nil
        return nil unless config.is_a?(Hash)
        return nil if config["due_on"].blank? || config["amount"].blank?

        config
      end

      def no_balloon
        { amount: 0.to_d, risk_flags: [], source_snapshot: {} }
      end

      # Resolve the scenario-supplied refinance override (a debt_terms_override
      # forecast event) that applies to this account on this period. The override
      # takes effect from effective_on onward: the latest override whose
      # effective_on <= period.end_date wins. Returns deterministic, scenario-scoped
      # overridden terms (rate/payment) plus a one-time cash-out drawdown applied
      # only on the period containing effective_on. Outside a scenario these events
      # are never present (input builder threads them via debt_sensitive_events) so
      # the baseline stack is unaffected.
      def refinance_override_for(account, period)
        account_overrides = forecast_debt_events.select do |row|
          row.fetch(:effect_type, nil) == "debt_terms_override" &&
            debt_effect_account_id(row) == account.id &&
            row.fetch(:refinance, nil).is_a?(Hash)
        end

        candidates = account_overrides.select do |row|
          (effective = parse_date(row.dig(:refinance, "effective_on"))).present? &&
            effective <= period.end_date
        end

        if candidates.empty?
          # If override events exist for this account but every effective_on failed
          # to parse, the override is silently dropped (no rate/payment/drawdown
          # change). Surface that loudly rather than pretending the scenario equals
          # baseline: an unparseable date must never make an override vanish without
          # an audit trail.
          unparseable = account_overrides.reject { |row| parse_date(row.dig(:refinance, "effective_on")).present? }
          return no_refinance if unparseable.empty?

          return unparseable_refinance(account, unparseable)
        end

        # Stable tie-break: latest effective_on wins; ties resolve by event id so the
        # result never depends on DB/array row order.
        winner = candidates.max_by do |row|
          [ parse_date(row.dig(:refinance, "effective_on")), row.dig(:source_snapshot, "id").to_s ]
        end
        refinance = winner.fetch(:refinance)
        effective_on = parse_date(refinance["effective_on"])

        overridden_terms = refinanced_terms(account, refinance)
        drawdown = refinance_drawdown_for(account, refinance, effective_on, period)

        {
          active: true,
          terms: overridden_terms,
          drawdown: drawdown.fetch(:amount),
          risk_flags: drawdown.fetch(:risk_flags),
          source_snapshot: {
            "applied" => true,
            "effective_on" => effective_on.iso8601,
            "new_annual_rate" => overridden_terms.annual_rate&.to_s,
            "new_monthly_payment" => overridden_terms.monthly_payment&.to_s,
            "new_principal_drawdown" => drawdown.fetch(:source_snapshot),
            "forecast_event_id" => winner.dig(:source_snapshot, "id")
          }
        }
      end

      def no_refinance
        { active: false, terms: nil, drawdown: 0.to_d, risk_flags: [], source_snapshot: { "applied" => false } }
      end

      # An override event existed for this account but its effective_on could not be
      # parsed into a real date, so no rate/payment/drawdown change is applied. We do
      # NOT silently fall back to baseline: emit a debt_projection_incomplete flag and
      # record the discarded event ids so the dropped override stays explainable.
      def unparseable_refinance(account, unparseable_events)
        discarded_ids = unparseable_events.map { |row| row.dig(:source_snapshot, "id") }
        {
          active: false,
          terms: nil,
          drawdown: 0.to_d,
          risk_flags: [
            {
              "type" => "debt_projection_incomplete",
              "account_id" => account.id,
              "reason" => "debt_terms_override_unparseable_effective_on"
            }
          ],
          source_snapshot: {
            "applied" => false,
            "discarded_reason" => "unparseable_effective_on",
            "discarded_forecast_event_ids" => discarded_ids,
            "discarded_effective_on_values" => unparseable_events.map { |row| row.dig(:refinance, "effective_on") }
          }
        }
      end

      # Build a frozen, deterministic terms struct from the refinance metadata. The
      # overridden rate/payment replace the resolved rate-period terms from
      # effective_on onward; currency defaults to the family currency. Falls back to
      # nil rate/payment when the metadata omits one so the adapter keeps modeling
      # the other dimension.
      def refinanced_terms(account, refinance)
        currency = refinance["currency"].presence || money_converter.currency
        annual_rate = refinance["new_annual_rate"].present? ? refinance["new_annual_rate"].to_d : nil
        monthly_payment = refinance["new_monthly_payment"].present? ? refinance["new_monthly_payment"].to_d : nil

        Debt::AccountTerms::Result.new(
          account: account,
          accrual_ready: annual_rate.present?,
          missing_fields: [],
          rate_type: "fixed",
          annual_rate: annual_rate,
          monthly_payment: monthly_payment,
          opening_balance: account.balance.to_d,
          currency: currency,
          source: "scenario_refinance"
        )
      end

      def refinance_drawdown_for(account, refinance, effective_on, period)
        return { amount: 0.to_d, risk_flags: [], source_snapshot: {} } if refinance["new_principal"].blank?
        return { amount: 0.to_d, risk_flags: [], source_snapshot: {} } unless period.start_date <= effective_on && effective_on <= period.end_date

        currency = refinance["currency"].presence || money_converter.currency
        converted = money_converter.convert(
          amount: refinance["new_principal"].to_d,
          currency: currency,
          source: "debt_account:#{account.id}:refinance_cash_out:#{effective_on}"
        )

        {
          amount: converted.amount,
          risk_flags: converted.risk_flags,
          source_snapshot: money_converter.snapshot_for(converted).merge("effective_on" => effective_on.iso8601)
        }
      end

      # Interest under a scenario refinance: a single fixed overridden rate applied
      # across the accrual window for this period. Deterministic (no clock/RNG) and
      # explainable via the rate_spans snapshot, mirroring the single-rate path.
      def refinanced_projected_interest(account, profile, terms, period, opening_balance, opening_conversion, forecast_last_accrued_on:, refinance:)
        unless terms.annual_rate.present?
          # A payment-only refinance (no new rate) cannot model interest; flag the row
          # as incomplete rather than presenting zero interest as fully modeled.
          return zero_projected_interest(
            "refinance_rate_not_provided",
            forecast_last_accrued_on: forecast_last_accrued_on,
            risk_flags: [ { "type" => "debt_projection_incomplete", "account_id" => account.id, "reason" => "refinance_rate_not_provided" } ]
          )
        end

        window = forecast_accrual_window(profile, as_of: period.end_date, forecast_last_accrued_on: forecast_last_accrued_on)
        return zero_projected_interest("accrual_schedule_not_due") unless window.fetch(:due)

        effective_on = parse_date(refinance.dig(:source_snapshot, "effective_on"))
        period_end = [ period.end_date, window.fetch(:period_end_on) ].min
        start_date = [ run_date, window.fetch(:period_start_on), profile.effective_start_on, effective_on ].compact.max
        return zero_projected_interest("no_days_in_period") if start_date > period_end

        federal_handler = Debt::FederalStudentLoan::AccrualHandler.new(profile)
        denominator = federal_handler.day_count_denominator
        days = (period_end - start_date).to_i + 1
        basis = non_federal_interest_basis(account, terms, opening_balance, projected_native_opening_balance(terms, opening_balance, opening_conversion), period_end)
        interest = (basis.fetch(:amount) * (terms.annual_rate.to_d / 100) * days / denominator).round(4)

        {
          amount: interest,
          forecast_last_accrued_on: period_end,
          risk_flags: basis.fetch(:risk_flags),
          source_snapshot: basis.fetch(:source_snapshot).merge(
            "amount" => interest.to_s,
            "currency" => money_converter.currency,
            "period_start_on" => start_date.iso8601,
            "period_end_on" => period_end.iso8601,
            "terms_source" => "scenario_refinance",
            "rate_spans" => [
              {
                "start_on" => start_date.iso8601,
                "end_on" => period_end.iso8601,
                "days" => days,
                "annual_rate" => terms.annual_rate.to_s,
                "terms_source" => "scenario_refinance",
                "interest" => interest.to_s
              }
            ]
          )
        }
      end

      def required_payment_for(account, period, payment, opening_balance, include_overdue: false)
        # Filter the (eager-loaded) debt_obligations collection in Ruby instead of
        # issuing a fresh `.where` per period. The full set is loaded once per
        # account by `accounts` (includes(:debt_obligations, ...)); enumerating it
        # here keeps the per-period cost as in-memory selection, not DB round-trips.
        statuses = %w[open partially_paid overdue paid]
        obligations = account.debt_obligations.to_a.select do |obligation|
          next false unless obligation.status.in?(statuses)

          if include_overdue
            obligation.due_on <= period.end_date
          else
            obligation.due_on >= period.start_date && obligation.due_on <= period.end_date
          end
        end
        # Stable ordering with an id tie-breaker so the same set of obligations
        # always resolves the same row regardless of DB row order. Provider/local
        # preference within a due window is applied below in Ruby, never via DB
        # ordering, so insertion order can never change the resolved amount.
        obligations = obligations.sort_by { |obligation| [ obligation.due_on, obligation_source_priority(obligation), obligation.id ] }

        if obligations.any?
          resolved = resolve_obligations_by_due_window(obligations)
          converted = resolved.filter_map do |entry|
            obligation = entry.fetch(:obligation)
            gross_amount = (obligation.minimum_payment_amount || obligation.statement_balance_amount || 0).to_d
            paid = eligible_paid_amount(obligation, target_currency: obligation.currency, as_of: period.end_date)
            paid_amount = paid.fetch(:amount)
            remaining_amount = [ gross_amount - paid_amount, 0.to_d ].max
            next if remaining_amount.zero?

            {
              obligation: obligation,
              obligation_source: entry.fetch(:obligation_source),
              superseded_local_obligation_id: entry.fetch(:superseded_local_obligation_id),
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
                "obligation_source" => row.fetch(:obligation_source),
                "superseded_local_obligation_id" => row.fetch(:superseded_local_obligation_id),
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

      # Group obligations by their due window (due_on) and, when both a
      # provider-sourced obligation and a locally-derived one fall in the same
      # window, prefer the provider one for the due amount while recording the
      # superseded local id for the audit trail. Within a window the inputs are
      # already stably ordered (due_on, source priority, id) so the winner is
      # deterministic and independent of insertion/DB row order. When no provider
      # obligation exists for a window, every local obligation in it is kept as-is
      # (no amount changes), preserving the prior behavior. The adapter only READS
      # here — it never posts, mutates, or supersedes obligations in the DB.
      def resolve_obligations_by_due_window(obligations)
        obligations.group_by(&:due_on).flat_map do |_due_on, window_obligations|
          providers = window_obligations.select { |obligation| provider_sourced_obligation?(obligation) }
          locals = window_obligations.reject { |obligation| provider_sourced_obligation?(obligation) }

          if providers.any?
            superseded_local_id = locals.first&.id
            providers.map.with_index do |obligation, index|
              {
                obligation: obligation,
                obligation_source: "provider",
                # Only the first/winning provider row in the window records the
                # superseded local id; additional provider rows are distinct
                # obligations rather than supersessions of the same local guess.
                superseded_local_obligation_id: index.zero? ? superseded_local_id : nil
              }
            end
          else
            locals.map do |obligation|
              { obligation: obligation, obligation_source: "local", superseded_local_obligation_id: nil }
            end
          end
        end
      end

      # Sort key fragment placing provider-sourced obligations ahead of local ones
      # within the same due window so the provider row is the stable winner.
      def obligation_source_priority(obligation)
        provider_sourced_obligation?(obligation) ? 0 : 1
      end

      # A provider-supplied obligation carries an external_id and a non-local
      # source. Locally-derived obligations are generated by Sure (source nil,
      # "manual", "sure", or the placeholder "local") and never override a provider
      # statement minimum.
      def provider_sourced_obligation?(obligation)
        obligation.external_id.present? && !obligation.source.to_s.in?(LOCAL_OBLIGATION_SOURCES)
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
        cutoff_date = [ as_of, run_date ].min
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
        [ periods.first.start_date, run_date ].max
      end

      def actual_payment_for(account, period)
        # Filter the (eager-loaded) debt_payment_allocations + entries in Ruby
        # rather than issuing a joined `.where` per period. The account preloads
        # `debt_payment_allocations: :entry`, so the per-period work is in-memory
        # selection. Ordering mirrors the prior SQL (entry date, then allocation
        # id) with a stable id tie-breaker so the resolved set never depends on DB
        # row order.
        cutoff = [ period.end_date, run_date ].min
        allocations = account.debt_payment_allocations.to_a
          .select { |allocation| allocation.status.in?(%w[allocated estimated]) }
          .select { |allocation| allocation.entry.present? && allocation.entry.date.present? }
          .select { |allocation| allocation.entry.date >= period.start_date && allocation.entry.date <= cutoff }
          .reject { |allocation| allocation.entry.excluded? || (allocation.entry.transaction? && allocation.entry.transaction.pending?) }
          .sort_by { |allocation| [ allocation.entry.date, allocation.id ] }

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

      # Resolve a per-period planned EXTRA payment from an optional, forward-compat
      # `extra["amortization"]` config on the debt profile. Returns a deterministic
      # extra-payment amount (family currency) to add on top of the baseline
      # projected payment, capped by the caller to opening_balance + interest. Only
      # applies to profile-backed (interest-modeled) rows; the account-balance-only
      # fallback ignores amortization entirely. Fails loud (MissingRate) on a
      # foreign extra payment with no FX rate.
      def amortization_extra_payment_for(account, profile, terms, period, opening_balance, projected_interest, baseline_projected_payment)
        config = amortization_config_for(profile)
        return no_amortization unless config

        strategy = config.fetch("strategy")
        case strategy
        when "fixed_extra"
          fixed_extra_amortization(account, profile, config, opening_balance, projected_interest, baseline_projected_payment)
        when "target_payoff"
          target_payoff_amortization(account, profile, terms, period, config, opening_balance, projected_interest, baseline_projected_payment)
        else
          no_amortization
        end
      end

      def amortization_config_for(profile)
        return nil if profile.blank?

        config = profile.extra.is_a?(Hash) ? profile.extra["amortization"] : nil
        return nil if config.blank?
        return nil unless config.is_a?(Hash)
        return nil if config["strategy"].blank?

        config
      end

      def no_amortization
        { applied_extra_payment: 0.to_d, risk_flags: [], source_snapshot: { "strategy" => "none", "applied_extra_payment" => "0" } }
      end

      def fixed_extra_amortization(account, profile, config, opening_balance, projected_interest, baseline_projected_payment, extra_risk_flags: [], strategy: "fixed_extra")
        converted = convert_extra_payment(account, config)
        # The extra payment can never exceed the balance still owed after the
        # baseline payment has been applied, so payoff cannot overshoot into a
        # negative balance.
        remaining_after_baseline = [ opening_balance + projected_interest - baseline_projected_payment, 0.to_d ].max
        applied = [ converted.amount, remaining_after_baseline ].min

        {
          applied_extra_payment: applied,
          risk_flags: converted.risk_flags + extra_risk_flags,
          source_snapshot: {
            "strategy" => strategy,
            "configured_extra_payment" => money_converter.snapshot_for(converted),
            "applied_extra_payment" => applied.to_s,
            "remaining_after_baseline" => remaining_after_baseline.to_s
          }
        }
      end

      def target_payoff_amortization(account, profile, terms, period, config, opening_balance, projected_interest, baseline_projected_payment)
        # Variable/adjustable rates cannot be solved with a single closed-form
        # level payment because future rates are unknown; fall back to fixed_extra
        # semantics and flag that the strategy was downgraded.
        if variable_rate_terms?(terms)
          flag = {
            "type" => "amortization_strategy_unsupported_for_variable",
            "account_id" => account.id,
            "reason" => "target_payoff_requires_fixed_rate",
            "rate_type" => terms.rate_type
          }
          return fixed_extra_amortization(account, profile, config, opening_balance, projected_interest, baseline_projected_payment, extra_risk_flags: [ flag ], strategy: "target_payoff")
        end

        target_date = parse_date(config["target_payoff_on"])
        if target_date.blank? || target_date < period.start_date
          return no_amortization.merge(
            source_snapshot: { "strategy" => "target_payoff", "applied_extra_payment" => "0", "reason" => "missing_or_past_target_date" }
          )
        end

        # Months remaining are measured from THIS period to the target so the level
        # payment re-solves each period against the carried opening balance and
        # deterministically converges to zero at the target period.
        months_remaining = [ months_between(period.start_date, target_date) + 1, 1 ].max
        level_payment = level_payment_for(opening_balance, terms.annual_rate, months_remaining)
        # The level payment is what SHOULD be paid this period to stay on the
        # target-payoff curve; the EXTRA is whatever exceeds the baseline payment.
        applied = [ level_payment - baseline_projected_payment, 0.to_d ].max
        remaining_after_baseline = [ opening_balance + projected_interest - baseline_projected_payment, 0.to_d ].max
        applied = [ applied, remaining_after_baseline ].min

        {
          applied_extra_payment: applied,
          risk_flags: [],
          source_snapshot: {
            "strategy" => "target_payoff",
            "target_payoff_on" => target_date.iso8601,
            "months_remaining" => months_remaining,
            "annual_rate" => terms.annual_rate&.to_s,
            "level_payment" => level_payment.to_s,
            "applied_extra_payment" => applied.to_s,
            "remaining_after_baseline" => remaining_after_baseline.to_s
          }
        }
      end

      # Standard amortizing level-payment closed form for a fixed periodic rate.
      # i == 0 reduces to principal / periods. Uses a monthly periodic convention
      # (annual_rate / 12) which is deterministic and independent of wall clock.
      def level_payment_for(principal, annual_rate, months)
        principal = principal.to_d
        return 0.to_d if principal.zero? || months <= 0

        periodic_rate = (annual_rate.to_d / 100) / 12
        return (principal / months).round(4) if periodic_rate.zero?

        growth = (1 + periodic_rate) ** months
        (principal * periodic_rate * growth / (growth - 1)).round(4)
      end

      def variable_rate_terms?(terms)
        terms.rate_type.to_s.in?(%w[variable adjustable])
      end

      def convert_extra_payment(account, config)
        amount = config["extra_payment_amount"].to_d
        currency = config["currency"].presence || money_converter.currency
        money_converter.convert(
          amount: amount,
          currency: currency,
          source: "debt_account:#{account.id}:amortization_extra_payment"
        )
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return nil if value.blank?

        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def months_between(from_date, to_date)
        (to_date.year * 12 + to_date.month) - (from_date.year * 12 + from_date.month)
      end
  end
end
